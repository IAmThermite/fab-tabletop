defmodule Tabletop.Tournaments do
  @moduledoc """
  The Tournaments context. Handles tournament lifecycle, registrations,
  pairings (via the pure engine under `Tournaments.Pairing`), rounds, and
  matches.

  Broadcasts:

    * `"tournaments"` topic — `{:tournaments_updated}` on create/status change.
    * `"tournament:\#{id}"` topic — `{:tournament_updated, id}` whenever any
      data attached to the tournament changes.
  """

  import Ecto.Query, warn: false

  alias Tabletop.Repo
  alias Tabletop.Accounts.Scope

  alias Tabletop.Tournaments.{
    Tournament,
    TournamentRegistration,
    TournamentRound,
    TournamentMatch
  }

  alias Tabletop.Tournaments.Pairing
  alias Tabletop.Tournaments.Pairing.{Bracket, Standings, Swiss}

  # Check-in must stay open at least this long before the tournament can start.
  # Overridable via app env (the test suite sets it to 0 to skip the wait).
  @default_check_in_min_seconds 300

  @doc """
  Number of seconds check-in must remain open before the tournament can start.
  """
  def check_in_min_seconds do
    Application.get_env(:tabletop, :check_in_min_seconds, @default_check_in_min_seconds)
  end

  @doc """
  The earliest moment a tournament in check-in may be started, or `nil` if
  check-in has not been opened.
  """
  def check_in_start_allowed_at(%Tournament{check_in_opened_at: nil}), do: nil

  def check_in_start_allowed_at(%Tournament{check_in_opened_at: opened_at}) do
    DateTime.add(opened_at, check_in_min_seconds(), :second)
  end

  @doc """
  True once the check-in window has been open for at least the required minimum.
  """
  def check_in_min_elapsed?(%Tournament{} = t) do
    case check_in_start_allowed_at(t) do
      nil -> false
      allowed_at -> DateTime.compare(DateTime.utc_now(), allowed_at) != :lt
    end
  end

  @doc """
  True once the tournament's scheduled start time has passed. Tournaments with
  no `starts_at` set carry no scheduled gate and are always ready.
  """
  def start_time_reached?(%Tournament{starts_at: nil}), do: true

  def start_time_reached?(%Tournament{starts_at: starts_at}) do
    DateTime.compare(DateTime.utc_now(), starts_at) != :lt
  end

  # ─────────── PubSub ───────────

  def subscribe_tournaments do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, "tournaments")
  end

  def subscribe_tournament(id) do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, "tournament:#{id}")
  end

  @doc """
  Subscribes the caller to a single user's notification stream. Messages are
  `{:user_notification, payload}` where `payload` is the map built by the
  `notify_*` helpers (`:type`, `:tournament_id`, `:tournament_name`,
  `:message`, `:path`). Used by the web layer to raise toasts on whatever page
  the player happens to be on.
  """
  def subscribe_user_notifications(user_id) when is_binary(user_id) do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, user_notifications_topic(user_id))
  end

  defp broadcast_list do
    Phoenix.PubSub.broadcast(Tabletop.PubSub, "tournaments", {:tournaments_updated})
  end

  defp broadcast_one(id) do
    Phoenix.PubSub.broadcast(Tabletop.PubSub, "tournament:#{id}", {:tournament_updated, id})
  end

  defp notify_user(nil, _payload), do: :ok

  defp notify_user(user_id, payload) do
    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      user_notifications_topic(user_id),
      {:user_notification, payload}
    )
  end

  defp user_notifications_topic(user_id), do: "user_notifications:#{user_id}"

  # ─────────── Reads ───────────

  def list_tournaments do
    from(t in Tournament, preload: [:created_by])
    |> Repo.all()
    |> Enum.sort_by(fn t -> {status_order(t.status), -DateTime.to_unix(t.inserted_at)} end)
    |> Enum.map(&with_player_count/1)
  end

  @doc """
  Tournaments to surface on the home page, split into `:upcoming` (open for
  sign-up or check-in) and `:in_progress` (Swiss or top cut). Each carries
  `active_player_count` and a preloaded `current_round` (for a round label).
  Upcoming are ordered soonest-start first (no start time last); in-progress by
  oldest first.
  """
  def list_home_tournaments do
    tournaments =
      from(t in Tournament,
        where: t.status in [:registration, :check_in, :swiss, :cut],
        preload: [:current_round]
      )
      |> Repo.all()
      |> Enum.map(&with_player_count/1)

    upcoming =
      tournaments
      |> Enum.filter(&(&1.status in [:registration, :check_in]))
      |> Enum.sort_by(&{starts_at_sort(&1.starts_at), DateTime.to_unix(&1.inserted_at)})

    in_progress =
      tournaments
      |> Enum.filter(&(&1.status in [:swiss, :cut]))
      |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at))

    %{upcoming: upcoming, in_progress: in_progress}
  end

  @doc """
  The most recently finished tournaments that crowned a champion, newest first.

  There is no dedicated `finished_at` column — finishing is the last thing that
  touches a finished tournament's row (`generate_top_cut`/`advance_bracket`
  stamp `winner_id` + `status`), so `updated_at` is the finish time. Each result
  has its `:winner` preloaded. `limit` caps the list (default 3).
  """
  def list_recent_winners(limit \\ 3) do
    from(t in Tournament,
      where: t.status == :finished and not is_nil(t.winner_id),
      order_by: [desc: t.updated_at, desc: t.inserted_at],
      limit: ^limit,
      preload: [:winner]
    )
    |> Repo.all()
    |> attach_winner_registrations()
  end

  # Attach each champion's own registration as virtual `winner_hero` /
  # `winner_decklist_url` fields (for the home-page winners card). One extra
  # query keyed by {tournament_id, winner_id} beats preloading every
  # registration just to find the winner's.
  defp attach_winner_registrations([]), do: []

  defp attach_winner_registrations(tournaments) do
    tournament_ids = Enum.map(tournaments, & &1.id)
    winner_ids = Enum.map(tournaments, & &1.winner_id)

    regs =
      from(r in TournamentRegistration,
        where: r.tournament_id in ^tournament_ids and r.user_id in ^winner_ids
      )
      |> Repo.all()
      |> Map.new(&{{&1.tournament_id, &1.user_id}, &1})

    Enum.map(tournaments, fn t ->
      reg = Map.get(regs, {t.id, t.winner_id})

      Map.merge(t, %{
        winner_hero: reg && reg.hero,
        winner_decklist_url: reg && reg.decklist_url
      })
    end)
  end

  # Sort key that puts tournaments with a start time first (soonest first) and
  # those without a start time last.
  defp starts_at_sort(nil), do: {1, 0}
  defp starts_at_sort(%DateTime{} = at), do: {0, DateTime.to_unix(at)}

  defp status_order(:registration), do: 0
  defp status_order(:check_in), do: 1
  defp status_order(:swiss), do: 2
  defp status_order(:cut), do: 3
  defp status_order(:draft), do: 4
  defp status_order(:finished), do: 5
  defp status_order(:cancelled), do: 6
  defp status_order(_), do: 7

  defp with_player_count(%Tournament{} = t) do
    count =
      Repo.aggregate(
        from(r in TournamentRegistration,
          where: r.tournament_id == ^t.id and is_nil(r.dropped_at)
        ),
        :count
      )

    Map.put(t, :active_player_count, count)
  end

  def get_tournament!(id) do
    Tournament
    |> Repo.get!(id)
    |> Repo.preload([:created_by, :winner, :current_round])
  end

  def list_registrations(tournament_id) do
    from(r in TournamentRegistration,
      where: r.tournament_id == ^tournament_id,
      order_by: [asc: r.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  def get_registration(tournament_id, user_id) do
    Repo.get_by(TournamentRegistration, tournament_id: tournament_id, user_id: user_id)
  end

  def list_rounds(tournament_id) do
    from(r in TournamentRound,
      where: r.tournament_id == ^tournament_id,
      order_by: [asc: r.round_number]
    )
    |> Repo.all()
  end

  def list_matches_for_round(round_id) do
    from(m in TournamentMatch,
      where: m.round_id == ^round_id,
      order_by: [asc: m.table_number],
      preload: [:player1, :player2]
    )
    |> Repo.all()
  end

  def get_match!(id) do
    TournamentMatch
    |> Repo.get!(id)
    |> Repo.preload([:player1, :player2, :round])
  end

  @doc """
  Returns the tournament match linked to the given game id, or nil.
  """
  def get_match_by_game_id(game_id) do
    Repo.get_by(TournamentMatch, game_id: game_id)
  end

  def current_match_for_user(_tournament_id, nil), do: nil

  def current_match_for_user(tournament_id, user_id) do
    tournament = Repo.get!(Tournament, tournament_id)

    case tournament.current_round_id do
      nil ->
        nil

      round_id ->
        from(m in TournamentMatch,
          where:
            m.round_id == ^round_id and
              (m.player1_id == ^user_id or m.player2_id == ^user_id),
          preload: [:player1, :player2, :round]
        )
        |> Repo.one()
    end
  end

  @doc """
  Returns standings as a list of maps (see `Pairing.Standings.compute/2`),
  each enriched with the user's name. Safe to call at any status.
  """
  def standings(tournament_id) do
    regs = list_registrations(tournament_id) |> Enum.reject(&(&1.user == nil))
    matches = list_confirmed_matches(tournament_id)
    players = to_pairing_players(regs, matches)
    rows = Standings.compute(players)

    user_by_id = Map.new(regs, fn r -> {r.user_id, r.user} end)
    reg_by_id = Map.new(regs, fn r -> {r.user_id, r} end)

    Enum.map(rows, fn row ->
      row
      |> Map.put(:user, Map.get(user_by_id, row.id))
      |> Map.put(:registration, Map.get(reg_by_id, row.id))
    end)
  end

  defp list_confirmed_matches(tournament_id) do
    from(m in TournamentMatch,
      where: m.tournament_id == ^tournament_id and not is_nil(m.confirmed_result),
      preload: [:round]
    )
    |> Repo.all()
  end

  @doc """
  Returns the outstanding things a player needs to act on across all
  tournaments, for rendering persistent banners. Each item is a map with
  `:type`, `:tournament_id`, `:tournament_name`, `:message`, and `:path`.

  Two kinds are surfaced:

    * `:check_in` — the player is registered for a tournament whose check-in is
      open and they haven't checked in yet.
    * `:match` — the player has an unfinished match in the current round.
  """
  def player_action_items(nil), do: []

  def player_action_items(user_id) when is_binary(user_id) do
    check_in_action_items(user_id) ++ match_action_items(user_id)
  end

  defp check_in_action_items(user_id) do
    from(r in TournamentRegistration,
      join: t in Tournament,
      on: t.id == r.tournament_id,
      where:
        r.user_id == ^user_id and is_nil(r.dropped_at) and is_nil(r.checked_in_at) and
          t.status == :check_in,
      select: %{tournament_id: t.id, tournament_name: t.name}
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        type: :check_in,
        tournament_id: row.tournament_id,
        tournament_name: row.tournament_name,
        message: "Check-in is open for #{row.tournament_name} — check in to play.",
        path: "/tournaments/#{row.tournament_id}"
      }
    end)
  end

  defp match_action_items(user_id) do
    from(m in TournamentMatch,
      join: t in Tournament,
      on: t.id == m.tournament_id,
      where:
        t.status in [:swiss, :cut] and m.round_id == t.current_round_id and
          is_nil(m.confirmed_result) and is_nil(m.player1_reported) and
          is_nil(m.player2_reported) and not is_nil(m.player2_id) and
          (m.player1_id == ^user_id or m.player2_id == ^user_id),
      select: %{tournament_id: t.id, tournament_name: t.name, game_id: m.game_id}
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        type: :match,
        tournament_id: row.tournament_id,
        tournament_name: row.tournament_name,
        message: "Your match in #{row.tournament_name} is ready.",
        path: match_path(row.game_id, row.tournament_id)
      }
    end)
  end

  defp match_path(nil, tournament_id), do: "/tournaments/#{tournament_id}"
  defp match_path(game_id, _tournament_id), do: "/games/#{game_id}"

  # ─────────── Player actions ───────────

  def change_registration(%TournamentRegistration{} = reg, attrs \\ %{}) do
    TournamentRegistration.changeset(reg, attrs)
  end

  def register(%Scope{user: user}, tournament_id, attrs) do
    t = get_tournament!(tournament_id)

    cond do
      t.status != :registration ->
        {:error, :registration_closed}

      player_count(t.id) >= t.max_players ->
        {:error, :tournament_full}

      true ->
        attrs =
          attrs
          |> Map.put("tournament_id", t.id)
          |> Map.put("user_id", user.id)

        %TournamentRegistration{}
        |> TournamentRegistration.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, reg} ->
            broadcast_one(t.id)
            {:ok, reg}

          error ->
            error
        end
    end
  end

  defp player_count(tournament_id) do
    Repo.aggregate(
      from(r in TournamentRegistration,
        where: r.tournament_id == ^tournament_id and is_nil(r.dropped_at)
      ),
      :count
    )
  end

  def drop(%Scope{user: user}, tournament_id) do
    case get_registration(tournament_id, user.id) do
      nil ->
        {:error, :not_registered}

      reg ->
        reg
        |> Ecto.Changeset.change(dropped_at: DateTime.utc_now())
        |> Repo.update()
        |> case do
          {:ok, reg} ->
            broadcast_one(tournament_id)
            {:ok, reg}

          error ->
            error
        end
    end
  end

  @doc """
  A registered player checks in during the check-in window. Idempotent — a
  second call leaves the original timestamp in place.
  """
  def check_in(%Scope{user: user}, tournament_id) do
    t = get_tournament!(tournament_id)

    cond do
      t.status != :check_in ->
        {:error, :check_in_closed}

      true ->
        case get_registration(tournament_id, user.id) do
          nil ->
            {:error, :not_registered}

          %TournamentRegistration{dropped_at: dropped} when not is_nil(dropped) ->
            {:error, :dropped}

          %TournamentRegistration{checked_in_at: checked_in} = reg
          when not is_nil(checked_in) ->
            {:ok, reg}

          reg ->
            reg
            |> Ecto.Changeset.change(checked_in_at: DateTime.utc_now())
            |> Repo.update()
            |> case do
              {:ok, reg} ->
                broadcast_one(tournament_id)
                {:ok, reg}

              error ->
                error
            end
        end
    end
  end

  @doc """
  A player reports the result of their current match.

  `which` is `:p1` or `:p2`, `result` is one of `"p1_win" | "p2_win" | "draw"`.
  """
  def report_result(%Scope{user: user}, match_id, result) do
    match = get_match!(match_id)

    which =
      cond do
        match.player1_id == user.id -> :p1
        match.player2_id == user.id -> :p2
        true -> nil
      end

    cond do
      which == nil ->
        {:error, :not_a_player}

      match.confirmed_result != nil ->
        {:error, :already_confirmed}

      true ->
        attrs =
          case which do
            :p1 -> %{player1_reported: result}
            :p2 -> %{player2_reported: result}
          end

        match
        |> TournamentMatch.report_changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, m} ->
            broadcast_one(match.tournament_id)
            notify_result_reported(match, user, which)
            {:ok, m}

          error ->
            error
        end
    end
  end

  # ─────────── Admin actions ───────────

  def change_tournament(%Tournament{} = t, attrs \\ %{}, scope) do
    Tournament.changeset(t, attrs, scope)
  end

  def create_tournament(%Scope{} = scope, attrs) do
    ensure_admin!(scope)

    %Tournament{}
    |> Tournament.changeset(attrs, scope)
    |> Repo.insert()
    |> case do
      {:ok, t} ->
        broadcast_list()
        {:ok, t}

      error ->
        error
    end
  end

  def update_tournament(%Scope{} = scope, %Tournament{} = t, attrs) do
    ensure_admin!(scope)

    t
    |> Tournament.changeset(attrs, scope)
    |> Repo.update()
    |> case do
      {:ok, t} ->
        broadcast_list()
        broadcast_one(t.id)
        {:ok, t}

      error ->
        error
    end
  end

  def open_registration(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)
    # Reopening registration (e.g. from check-in) resets the check-in window.
    update_status(t, :registration, %{check_in_opened_at: nil})
  end

  @doc """
  Opens the check-in window. Players must check in before the admin starts the
  tournament; anyone who hasn't is dropped at start. Registration is closed for
  the duration (sign-ups are only accepted in `:registration`). Opening check-in
  clears any prior check-in marks so each window starts fresh.
  """
  def open_check_in(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)

    active = list_registrations(t.id) |> Enum.reject(& &1.dropped_at)

    cond do
      t.status != :registration ->
        {:error, :wrong_status}

      length(active) < 2 ->
        {:error, :not_enough_players}

      true ->
        do_open_check_in(t, active)
    end
  end

  defp do_open_check_in(%Tournament{} = t, active) do
    Repo.transaction(fn ->
      from(r in TournamentRegistration, where: r.tournament_id == ^t.id)
      |> Repo.update_all(set: [checked_in_at: nil])

      t
      |> Tournament.status_changeset(%{
        status: :check_in,
        check_in_opened_at: DateTime.utc_now()
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, t} ->
        broadcast_list()
        broadcast_one(t.id)
        notify_check_in_open(t, active)
        {:ok, t}

      error ->
        error
    end
  end

  def start_tournament(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)

    regs = list_registrations(t.id) |> Enum.reject(& &1.dropped_at)
    {checked_in, not_checked_in} = Enum.split_with(regs, & &1.checked_in_at)

    cond do
      t.status != :check_in ->
        {:error, :wrong_status}

      not start_time_reached?(t) ->
        {:error, :before_start_time}

      not check_in_min_elapsed?(t) ->
        {:error, :check_in_too_soon}

      length(checked_in) < 2 ->
        {:error, :not_enough_players}

      true ->
        Repo.transaction(fn ->
          now = DateTime.utc_now()

          # Players who never checked in are dropped before pairing.
          Enum.each(not_checked_in, fn reg ->
            reg
            |> Ecto.Changeset.change(dropped_at: now)
            |> Repo.update!()
          end)

          checked_in
          |> Enum.with_index(1)
          |> Enum.each(fn {reg, idx} ->
            reg
            |> Ecto.Changeset.change(seed: idx)
            |> Repo.update!()
          end)

          t = t |> Ecto.Changeset.change(status: :swiss) |> Repo.update!()
          {:ok, round} = do_generate_swiss_round(t, 1)

          t
          |> Ecto.Changeset.change(current_round_id: round.id)
          |> Repo.update!()
        end)
        |> case do
          {:ok, t} ->
            broadcast_list()
            broadcast_one(t.id)
            notify_new_round(t, t.current_round_id)
            {:ok, t}

          error ->
            error
        end
    end
  end

  def generate_next_swiss_round(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)

    completed = Enum.count(list_rounds(t.id), & &1.completed_at)
    next_number = completed + 1

    cond do
      t.status != :swiss ->
        {:error, :wrong_status}

      not round_fully_confirmed?(t) ->
        {:error, :round_incomplete}

      next_number > t.swiss_rounds ->
        {:error, :swiss_complete}

      true ->
        Repo.transaction(fn ->
          {:ok, round} = do_generate_swiss_round(t, next_number)

          t
          |> Ecto.Changeset.change(current_round_id: round.id)
          |> Repo.update!()
        end)
        |> case do
          {:ok, t} ->
            broadcast_one(t.id)
            notify_new_round(t, t.current_round_id)
            {:ok, t}

          error ->
            error
        end
    end
  end

  defp do_generate_swiss_round(%Tournament{} = t, number) do
    regs = list_registrations(t.id)
    matches = list_confirmed_matches(t.id)
    players = to_pairing_players(regs, matches)

    {:ok, %{pairings: pairings, bye: bye_id}} = Swiss.pair(players, number)

    round =
      %TournamentRound{}
      |> TournamentRound.changeset(%{
        tournament_id: t.id,
        round_number: number,
        kind: :swiss,
        started_at: DateTime.utc_now(),
        deadline_at: DateTime.add(DateTime.utc_now(), t.round_duration_seconds, :second)
      })
      |> Repo.insert!()

    pairings
    |> Enum.with_index(1)
    |> Enum.each(fn {{p1, p2}, idx} ->
      game = create_match_game!(t, round, idx, p1, p2)

      %TournamentMatch{}
      |> TournamentMatch.new_changeset(%{
        tournament_id: t.id,
        round_id: round.id,
        table_number: idx,
        player1_id: p1,
        player2_id: p2
      })
      |> Ecto.Changeset.put_change(:game_id, game.id)
      |> Repo.insert!()
    end)

    if bye_id do
      %TournamentMatch{}
      |> TournamentMatch.new_changeset(%{
        tournament_id: t.id,
        round_id: round.id,
        table_number: length(pairings) + 1,
        player1_id: bye_id,
        player2_id: nil
      })
      |> TournamentMatch.confirm_changeset(%{
        confirmed_result: "bye",
        confirmed_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    {:ok, round}
  end

  def generate_top_cut(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)

    cond do
      t.status != :swiss ->
        {:error, :wrong_status}

      not round_fully_confirmed?(t) ->
        {:error, :round_incomplete}

      t.top_cut_size in [0, nil] ->
        # No cut configured — jump straight to finished based on standings.
        finish_from_standings(t)

      true ->
        rows = standings(t.id) |> Enum.take(t.top_cut_size)
        ids = Enum.map(rows, & &1.id)

        Repo.transaction(fn ->
          t = t |> Ecto.Changeset.change(status: :cut) |> Repo.update!()
          round = create_cut_round(t, 1, ids)

          t
          |> Ecto.Changeset.change(current_round_id: round.id)
          |> Repo.update!()
        end)
        |> case do
          {:ok, t} ->
            broadcast_one(t.id)
            notify_new_round(t, t.current_round_id)
            {:ok, t}

          error ->
            error
        end
    end
  end

  defp create_cut_round(%Tournament{} = t, cut_stage, seeded_ids) do
    rounds = list_rounds(t.id)
    number = length(rounds) + 1

    round =
      %TournamentRound{}
      |> TournamentRound.changeset(%{
        tournament_id: t.id,
        round_number: number,
        kind: :top_cut,
        cut_stage: cut_stage,
        started_at: DateTime.utc_now(),
        deadline_at: DateTime.add(DateTime.utc_now(), t.round_duration_seconds, :second)
      })
      |> Repo.insert!()

    pairings = Bracket.seed(seeded_ids)

    pairings
    |> Enum.with_index(1)
    |> Enum.each(fn {{p1, p2}, idx} ->
      game = create_match_game!(t, round, idx, p1, p2)

      %TournamentMatch{}
      |> TournamentMatch.new_changeset(%{
        tournament_id: t.id,
        round_id: round.id,
        table_number: idx,
        player1_id: p1,
        player2_id: p2
      })
      |> Ecto.Changeset.put_change(:game_id, game.id)
      |> Repo.insert!()
    end)

    round
  end

  defp create_match_game!(%Tournament{} = t, round, table_number, p1_id, p2_id)
       when not is_nil(p2_id) do
    title = "#{t.name} — #{round_short_label(round)} · Table #{table_number}"

    %Tabletop.Games.Game{}
    |> Tabletop.Games.Game.match_changeset(%{
      title: title,
      format: t.format,
      status: :active,
      user_id: p1_id,
      user2_id: p2_id
    })
    |> Repo.insert!()
  end

  defp round_short_label(%{kind: :swiss, round_number: n}), do: "Swiss #{n}"

  defp round_short_label(%{kind: :top_cut, cut_stage: stage, round_number: n}),
    do: "Cut R#{stage || n}"

  def advance_bracket(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)

    cond do
      t.status != :cut ->
        {:error, :wrong_status}

      not round_fully_confirmed?(t) ->
        {:error, :round_incomplete}

      true ->
        current_round = Repo.get!(TournamentRound, t.current_round_id)
        matches = list_matches_for_round(current_round.id)

        results =
          Enum.map(matches, fn m ->
            winner =
              case m.confirmed_result do
                "p1_win" -> m.player1_id
                "p2_win" -> m.player2_id
                _ -> m.player1_id
              end

            %{pair: {m.player1_id, m.player2_id}, winner: winner}
          end)

        case Bracket.advance(results) do
          {:done, champion_id} ->
            t
            |> Tournament.status_changeset(%{status: :finished, winner_id: champion_id})
            |> Repo.update()
            |> tap(fn _ -> broadcast_list() end)
            |> tap(fn _ -> broadcast_one(t.id) end)
            |> tap(fn _ -> notify_finished(t, champion_id) end)

          {:next, pairings} ->
            Repo.transaction(fn ->
              round =
                create_cut_round(
                  t,
                  (current_round.cut_stage || 0) + 1,
                  pairings_to_seeded_ids(pairings)
                )

              t
              |> Ecto.Changeset.change(current_round_id: round.id)
              |> Repo.update!()
            end)
            |> case do
              {:ok, t} ->
                broadcast_one(t.id)
                notify_new_round(t, t.current_round_id)
                {:ok, t}

              error ->
                error
            end
        end
    end
  end

  defp pairings_to_seeded_ids(pairings) do
    # `Bracket.advance` already preserves winner order; flatten to list of ids.
    Enum.flat_map(pairings, fn {a, b} -> [a, b] end)
  end

  # ─────────── Player notifications ───────────

  # Tell every still-registered player the check-in window has opened.
  defp notify_check_in_open(%Tournament{} = t, registrations) do
    Enum.each(registrations, fn reg ->
      notify_user(reg.user_id, %{
        type: :check_in,
        tournament_id: t.id,
        tournament_name: t.name,
        message: "Check-in is open for #{t.name} — check in to play.",
        path: "/tournaments/#{t.id}"
      })
    end)
  end

  # Tell each player their pairing for a freshly generated round (or their bye).
  defp notify_new_round(%Tournament{} = t, round_id) do
    round = Repo.get!(TournamentRound, round_id)

    round_id
    |> list_matches_for_round()
    |> Enum.each(fn m ->
      if is_nil(m.player2_id) do
        notify_user(m.player1_id, %{
          type: :bye,
          tournament_id: t.id,
          tournament_name: t.name,
          message: "#{t.name}: you have a bye in #{round_short_label(round)}.",
          path: "/tournaments/#{t.id}"
        })
      else
        notify_user(m.player1_id, match_ready_payload(t, round, m, m.player2))
        notify_user(m.player2_id, match_ready_payload(t, round, m, m.player1))
      end
    end)
  end

  defp match_ready_payload(%Tournament{} = t, round, m, opponent) do
    opp = (opponent && opponent.name) || "your opponent"

    %{
      type: :match,
      tournament_id: t.id,
      tournament_name: t.name,
      message: "#{t.name}: your #{round_short_label(round)} match vs #{opp} is ready.",
      path: match_path(m.game_id, t.id)
    }
  end

  # Tell the opponent a result was reported for their match and now awaits
  # agreement/confirmation. The reporter doesn't need telling — they just acted.
  defp notify_result_reported(%TournamentMatch{} = match, reporter, which) do
    opponent_id = if which == :p1, do: match.player2_id, else: match.player1_id

    if opponent_id do
      t = Repo.get!(Tournament, match.tournament_id)

      notify_user(opponent_id, %{
        type: :result,
        tournament_id: t.id,
        tournament_name: t.name,
        message:
          "#{t.name}: #{reporter.name} reported your #{round_short_label(match.round)} result.",
        path: match_path(match.game_id, t.id)
      })
    end
  end

  # Tell both players a match result has been confirmed (or overridden) by an
  # admin and is now final.
  defp notify_result_confirmed(%TournamentMatch{} = match, result) do
    t = Repo.get!(Tournament, match.tournament_id)
    round_label = round_short_label(match.round)

    for uid <- [match.player1_id, match.player2_id], not is_nil(uid) do
      notify_user(uid, %{
        type: :result,
        tournament_id: t.id,
        tournament_name: t.name,
        message:
          "#{t.name}: your #{round_label} match is confirmed — #{result_outcome_for(uid, match, result)}.",
        path: "/tournaments/#{t.id}"
      })
    end
  end

  # The result string from the match's perspective, phrased for `uid`.
  defp result_outcome_for(_uid, _match, "draw"), do: "a draw"
  defp result_outcome_for(_uid, _match, "double_loss"), do: "a double loss"
  defp result_outcome_for(_uid, _match, "bye"), do: "a bye"

  defp result_outcome_for(uid, match, "p1_win"),
    do: if(uid == match.player1_id, do: "a win", else: "a loss")

  defp result_outcome_for(uid, match, "p2_win"),
    do: if(uid == match.player2_id, do: "a win", else: "a loss")

  # Tell every active player the tournament is over (and the winner they are).
  defp notify_finished(%Tournament{} = t, winner_id) do
    winner_name =
      case winner_id && Repo.get(Tabletop.Accounts.User, winner_id) do
        %{name: name} -> name
        _ -> nil
      end

    from(r in TournamentRegistration,
      where: r.tournament_id == ^t.id and is_nil(r.dropped_at),
      select: r.user_id
    )
    |> Repo.all()
    |> Enum.each(fn uid ->
      message =
        cond do
          uid == winner_id -> "You won #{t.name}! 🏆"
          winner_name -> "#{t.name} has finished — #{winner_name} is the champion."
          true -> "#{t.name} has finished."
        end

      notify_user(uid, %{
        type: :finished,
        tournament_id: t.id,
        tournament_name: t.name,
        message: message,
        path: "/tournaments/#{t.id}"
      })
    end)
  end

  def confirm_match(%Scope{user: user} = scope, match_id) do
    ensure_admin!(scope)
    match = get_match!(match_id)

    result =
      cond do
        match.player1_reported && match.player1_reported == match.player2_reported ->
          match.player1_reported

        true ->
          nil
      end

    if result do
      do_confirm(match, result, user.id)
    else
      {:error, :reports_disagree}
    end
  end

  def override_match(%Scope{user: user} = scope, match_id, result) do
    ensure_admin!(scope)

    unless result in TournamentMatch.confirmed_values() do
      raise ArgumentError, "invalid result: #{inspect(result)}"
    end

    match = get_match!(match_id)
    do_confirm(match, result, user.id)
  end

  defp do_confirm(%TournamentMatch{} = match, result, admin_id) do
    match
    |> TournamentMatch.confirm_changeset(%{
      confirmed_result: result,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_id: admin_id
    })
    |> Repo.update()
    |> case do
      {:ok, m} ->
        finish_match_game(match)
        maybe_complete_round(match.round_id)
        broadcast_one(match.tournament_id)
        notify_result_confirmed(match, result)
        {:ok, m}

      error ->
        error
    end
  end

  # A confirmed result ends the match's game. Marking it finished frees both
  # players from the one-active-game-per-user constraint so the next round can
  # create their next game. Byes have no linked game.
  defp finish_match_game(%TournamentMatch{game_id: nil}), do: :ok

  defp finish_match_game(%TournamentMatch{game_id: game_id}) do
    case Repo.get(Tabletop.Games.Game, game_id) do
      nil ->
        :ok

      game ->
        now = DateTime.utc_now()

        game
        |> Ecto.Changeset.change(%{
          status: :finished,
          user1_left_at: game.user1_left_at || now,
          user2_left_at: game.user2_left_at || now
        })
        |> Repo.update!()

        :ok
    end
  end

  defp maybe_complete_round(round_id) do
    round = Repo.get!(TournamentRound, round_id)

    if round.completed_at do
      :ok
    else
      remaining =
        Repo.aggregate(
          from(m in TournamentMatch,
            where: m.round_id == ^round_id and is_nil(m.confirmed_result)
          ),
          :count
        )

      if remaining == 0 do
        round
        |> Ecto.Changeset.change(completed_at: DateTime.utc_now())
        |> Repo.update!()
      end

      :ok
    end
  end

  def extend_round(%Scope{} = scope, round_id, extra_seconds)
      when is_integer(extra_seconds) do
    ensure_admin!(scope)
    round = Repo.get!(TournamentRound, round_id)

    new_deadline =
      case round.deadline_at do
        nil -> DateTime.add(DateTime.utc_now(), extra_seconds, :second)
        existing -> DateTime.add(existing, extra_seconds, :second)
      end

    round
    |> Ecto.Changeset.change(deadline_at: new_deadline)
    |> Repo.update()
    |> case do
      {:ok, r} ->
        broadcast_one(r.tournament_id)
        {:ok, r}

      error ->
        error
    end
  end

  def admin_drop_player(%Scope{} = scope, tournament_id, user_id) do
    ensure_admin!(scope)

    case get_registration(tournament_id, user_id) do
      nil ->
        {:error, :not_registered}

      reg ->
        reg
        |> Ecto.Changeset.change(dropped_at: DateTime.utc_now())
        |> Repo.update()
        |> case do
          {:ok, reg} ->
            broadcast_one(tournament_id)
            {:ok, reg}

          error ->
            error
        end
    end
  end

  @doc """
  Hard-removes a registration. Only allowed before the tournament has started
  (status `:draft` or `:registration`). Use `admin_drop_player/3` once the
  tournament is underway so scoring history is preserved.
  """
  def remove_registration(%Scope{} = scope, tournament_id, user_id) do
    ensure_admin!(scope)
    t = Repo.get!(Tournament, tournament_id)

    cond do
      t.status not in [:draft, :registration] ->
        {:error, :tournament_started}

      true ->
        case get_registration(tournament_id, user_id) do
          nil ->
            {:error, :not_registered}

          reg ->
            case Repo.delete(reg) do
              {:ok, reg} ->
                broadcast_one(tournament_id)
                {:ok, reg}

              error ->
                error
            end
        end
    end
  end

  def cancel_tournament(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)
    update_status(t, :cancelled)
  end

  defp finish_from_standings(%Tournament{} = t) do
    rows = standings(t.id)
    winner_id = rows |> List.first() |> Map.get(:id)

    t
    |> Tournament.status_changeset(%{status: :finished, winner_id: winner_id})
    |> Repo.update()
    |> case do
      {:ok, t} ->
        broadcast_list()
        broadcast_one(t.id)
        notify_finished(t, winner_id)
        {:ok, t}

      error ->
        error
    end
  end

  # ─────────── Helpers ───────────

  defp update_status(%Tournament{} = t, status, extra \\ %{}) do
    t
    |> Tournament.status_changeset(Map.put(extra, :status, status))
    |> Repo.update()
    |> case do
      {:ok, t} ->
        broadcast_list()
        broadcast_one(t.id)
        {:ok, t}

      error ->
        error
    end
  end

  defp round_fully_confirmed?(%Tournament{current_round_id: nil}), do: true

  defp round_fully_confirmed?(%Tournament{current_round_id: round_id}) do
    remaining =
      Repo.aggregate(
        from(m in TournamentMatch,
          where: m.round_id == ^round_id and is_nil(m.confirmed_result)
        ),
        :count
      )

    remaining == 0
  end

  defp ensure_admin!(scope) do
    unless Scope.admin?(scope), do: raise(Tabletop.Tournaments.NotAdminError)
    :ok
  end

  # ─────────── Ecto ↔ Pairing translation ───────────

  defp to_pairing_players(registrations, confirmed_matches) do
    # Only Swiss matches feed the standings/pairing tiebreakers — top-cut
    # (single-elim) results never affect match points, CMP, MLP, etc.
    agg =
      confirmed_matches
      |> Enum.filter(fn m -> match?(%{kind: :swiss}, m.round) end)
      |> Enum.reduce(%{}, fn m, acc ->
        apply_result(acc, m.round.round_number, m.player1_id, m.player2_id, m.confirmed_result)
      end)

    Enum.map(registrations, fn reg ->
      stats = Map.get(agg, reg.user_id, default_stats())

      %Pairing.Player{
        id: reg.user_id,
        wins: stats.wins,
        losses: stats.losses,
        draws: stats.draws,
        round_results: Enum.sort_by(stats.round_results, & &1.round),
        opponents: Enum.reverse(stats.opponents),
        had_bye: stats.had_bye,
        dropped: !is_nil(reg.dropped_at),
        seed: reg.seed
      }
    end)
  end

  defp default_stats do
    %{wins: 0, losses: 0, draws: 0, round_results: [], opponents: [], had_bye: false}
  end

  defp apply_result(acc, round, p1, p2, result) do
    case result do
      "bye" ->
        update_player(acc, p1, fn s ->
          %{
            s
            | wins: s.wins + 1,
              had_bye: true,
              round_results: [%{round: round, result: :bye} | s.round_results]
          }
        end)

      "p1_win" ->
        acc
        |> update_player(p1, &record_result(&1, round, :win, p2))
        |> update_player(p2, &record_result(&1, round, :loss, p1))

      "p2_win" ->
        acc
        |> update_player(p2, &record_result(&1, round, :win, p1))
        |> update_player(p1, &record_result(&1, round, :loss, p2))

      "draw" ->
        acc
        |> update_player(p1, &record_result(&1, round, :draw, p2))
        |> update_player(p2, &record_result(&1, round, :draw, p1))

      "double_loss" ->
        acc
        |> update_player(p1, &record_result(&1, round, :loss, p2))
        |> update_player(p2, &record_result(&1, round, :loss, p1))

      _ ->
        acc
    end
  end

  # Folds a single non-bye match result into a player's running stats: bumps the
  # win/loss/draw tally, appends the per-round outcome, and records the opponent.
  defp record_result(stats, round, result, opponent) do
    stats
    |> bump_tally(result)
    |> Map.update!(:round_results, &[%{round: round, result: result} | &1])
    |> Map.update!(:opponents, &[opponent | &1])
  end

  defp bump_tally(s, :win), do: %{s | wins: s.wins + 1}
  defp bump_tally(s, :loss), do: %{s | losses: s.losses + 1}
  defp bump_tally(s, :draw), do: %{s | draws: s.draws + 1}

  defp update_player(acc, nil, _fun), do: acc

  defp update_player(acc, id, fun) do
    Map.update(acc, id, fun.(default_stats()), fun)
  end

  @doc """
  True if the currently-open round has every match confirmed (so admin can
  advance). Exposed for UI.
  """
  def current_round_complete?(%Tournament{} = t), do: round_fully_confirmed?(t)

  @doc """
  Number of completed rounds (used to decide if swiss is done).
  """
  def completed_round_count(%Tournament{} = t) do
    from(r in TournamentRound,
      where: r.tournament_id == ^t.id and not is_nil(r.completed_at)
    )
    |> Repo.aggregate(:count)
  end
end
