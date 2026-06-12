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

  # ─────────── PubSub ───────────

  def subscribe_tournaments do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, "tournaments")
  end

  def subscribe_tournament(id) do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, "tournament:#{id}")
  end

  defp broadcast_list do
    Phoenix.PubSub.broadcast(Tabletop.PubSub, "tournaments", {:tournaments_updated})
  end

  defp broadcast_one(id) do
    Phoenix.PubSub.broadcast(Tabletop.PubSub, "tournament:#{id}", {:tournament_updated, id})
  end

  # ─────────── Reads ───────────

  def list_tournaments do
    from(t in Tournament, preload: [:created_by])
    |> Repo.all()
    |> Enum.sort_by(fn t -> {status_order(t.status), -DateTime.to_unix(t.inserted_at)} end)
    |> Enum.map(&with_player_count/1)
  end

  defp status_order(:registration), do: 0
  defp status_order(:swiss), do: 1
  defp status_order(:cut), do: 2
  defp status_order(:draft), do: 3
  defp status_order(:finished), do: 4
  defp status_order(:cancelled), do: 5
  defp status_order(_), do: 6

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
      where: m.tournament_id == ^tournament_id and not is_nil(m.confirmed_result)
    )
    |> Repo.all()
  end

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
    update_status(t, :registration)
  end

  def start_tournament(%Scope{} = scope, %Tournament{} = t) do
    ensure_admin!(scope)

    regs = list_registrations(t.id) |> Enum.reject(& &1.dropped_at)

    if length(regs) < 2 do
      {:error, :not_enough_players}
    else
      Repo.transaction(fn ->
        regs
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
        {:ok, t}

      error ->
        error
    end
  end

  # ─────────── Helpers ───────────

  defp update_status(%Tournament{} = t, status) do
    t
    |> Tournament.status_changeset(%{status: status})
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
    agg =
      Enum.reduce(confirmed_matches, %{}, fn m, acc ->
        acc
        |> apply_result(
          m.player1_id,
          m.player2_id,
          m.confirmed_result,
          m.player1_games_won || 0,
          m.player2_games_won || 0
        )
      end)

    Enum.map(registrations, fn reg ->
      stats = Map.get(agg, reg.user_id, default_stats())

      %Pairing.Player{
        id: reg.user_id,
        wins: stats.wins,
        losses: stats.losses,
        draws: stats.draws,
        game_wins: stats.game_wins,
        game_losses: stats.game_losses,
        game_draws: stats.game_draws,
        opponents: Enum.reverse(stats.opponents),
        had_bye: stats.had_bye,
        dropped: !is_nil(reg.dropped_at),
        seed: reg.seed
      }
    end)
  end

  defp default_stats do
    %{
      wins: 0,
      losses: 0,
      draws: 0,
      game_wins: 0,
      game_losses: 0,
      game_draws: 0,
      opponents: [],
      had_bye: false
    }
  end

  defp apply_result(acc, p1, p2, result, gw1, gw2) do
    case result do
      "bye" ->
        acc
        |> update_player(p1, fn s ->
          %{s | wins: s.wins + 1, had_bye: true}
        end)

      "p1_win" ->
        acc
        |> update_player(p1, fn s ->
          %{
            s
            | wins: s.wins + 1,
              game_wins: s.game_wins + gw1,
              game_losses: s.game_losses + gw2,
              opponents: [p2 | s.opponents]
          }
        end)
        |> update_player(p2, fn s ->
          %{
            s
            | losses: s.losses + 1,
              game_wins: s.game_wins + gw2,
              game_losses: s.game_losses + gw1,
              opponents: [p1 | s.opponents]
          }
        end)

      "p2_win" ->
        acc
        |> update_player(p2, fn s ->
          %{
            s
            | wins: s.wins + 1,
              game_wins: s.game_wins + gw2,
              game_losses: s.game_losses + gw1,
              opponents: [p1 | s.opponents]
          }
        end)
        |> update_player(p1, fn s ->
          %{
            s
            | losses: s.losses + 1,
              game_wins: s.game_wins + gw1,
              game_losses: s.game_losses + gw2,
              opponents: [p2 | s.opponents]
          }
        end)

      "draw" ->
        acc
        |> update_player(p1, fn s ->
          %{
            s
            | draws: s.draws + 1,
              game_wins: s.game_wins + gw1,
              game_losses: s.game_losses + gw2,
              opponents: [p2 | s.opponents]
          }
        end)
        |> update_player(p2, fn s ->
          %{
            s
            | draws: s.draws + 1,
              game_wins: s.game_wins + gw2,
              game_losses: s.game_losses + gw1,
              opponents: [p1 | s.opponents]
          }
        end)

      "double_loss" ->
        acc
        |> update_player(p1, fn s ->
          %{s | losses: s.losses + 1, opponents: [p2 | s.opponents]}
        end)
        |> update_player(p2, fn s ->
          %{s | losses: s.losses + 1, opponents: [p1 | s.opponents]}
        end)

      _ ->
        acc
    end
  end

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
