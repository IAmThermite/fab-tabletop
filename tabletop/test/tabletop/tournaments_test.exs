defmodule Tabletop.TournamentsTest do
  use Tabletop.DataCase, async: false

  import Tabletop.AccountsFixtures
  import Tabletop.TournamentsFixtures

  alias Tabletop.Accounts.Scope
  alias Tabletop.Tournaments

  setup do
    admin_scope = admin_scope_fixture()
    {:ok, admin_scope: admin_scope}
  end

  test "admin can create a tournament, players register, and swiss runs", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    assert {:ok, t} = Tournaments.open_registration(admin, t)
    assert t.status == :registration

    # Register 4 players.
    players =
      for _ <- 1..4 do
        s = Scope.for_user(user_fixture())

        {:ok, _reg} =
          Tournaments.register(s, t.id, %{
            "hero" => "Bravo",
            "decklist_url" => valid_fabrary_url()
          })

        s
      end

    assert {:ok, t} = Tournaments.open_check_in(admin, t)
    assert t.status == :check_in
    for s <- players, do: assert({:ok, _} = Tournaments.check_in(s, t.id))

    assert {:ok, t} = Tournaments.start_tournament(admin, t)
    assert t.status == :swiss
    assert t.current_round_id

    matches = Tournaments.list_matches_for_round(t.current_round_id)
    assert length(matches) == 2

    # Admin confirms each match with overrides.
    for m <- matches do
      assert {:ok, _} = Tournaments.override_match(admin, m.id, "p1_win")
    end

    assert t = Tournaments.get_tournament!(t.id)
    assert Tournaments.current_round_complete?(t)

    assert {:ok, t} = Tournaments.generate_next_swiss_round(admin, t)
    round2 = Tournaments.list_matches_for_round(t.current_round_id)
    assert length(round2) == 2

    # Confirm round 2.
    for m <- round2 do
      assert {:ok, _} = Tournaments.override_match(admin, m.id, "p1_win")
    end

    # Standings should be populated.
    rows = Tournaments.standings(t.id)
    assert length(rows) == 4
    assert List.first(rows).rank == 1

    # No cut configured → finishes.
    t = Tournaments.get_tournament!(t.id)
    assert {:ok, t} = Tournaments.generate_top_cut(admin, t)
    assert t.status == :finished
    assert t.winner_id

    _ = players
  end

  test "non-admin cannot create a tournament" do
    user_scope = Scope.for_user(user_fixture())

    assert_raise Tabletop.Tournaments.NotAdminError, fn ->
      Tournaments.create_tournament(user_scope, %{
        "name" => "x",
        "format" => "classic_constructed"
      })
    end
  end

  test "rejects invalid fabrary URLs", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, _} = Tournaments.open_registration(admin, t)
    s = Scope.for_user(user_fixture())

    assert {:error, changeset} =
             Tournaments.register(s, t.id, %{"decklist_url" => "https://evil.example.com/x"})

    assert %{decklist_url: _} = errors_on(changeset)
  end

  test "players can register, report, and admin confirms", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    [s1, s2] =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())

        {:ok, _} =
          Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})

        s
      end

    {:ok, t} = Tournaments.open_check_in(admin, t)
    for s <- [s1, s2], do: {:ok, _} = Tournaments.check_in(s, t.id)
    {:ok, t} = Tournaments.start_tournament(admin, t)
    [match] = Tournaments.list_matches_for_round(t.current_round_id)

    # Determine which player is p1.
    report = if match.player1_id == s1.user.id, do: "p1_win", else: "p2_win"

    assert {:ok, _} = Tournaments.report_result(s1, match.id, report)
    # Disagreement not yet — only one side reported.
    assert {:error, :reports_disagree} = Tournaments.confirm_match(admin, match.id)

    # Other side agrees.
    assert {:ok, _} = Tournaments.report_result(s2, match.id, report)
    assert {:ok, m} = Tournaments.confirm_match(admin, match.id)
    assert m.confirmed_result == report
  end

  test "opening check-in closes registration and drops un-checked-in players on start",
       %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    [s1, s2, s3] =
      for _ <- 1..3 do
        s = Scope.for_user(user_fixture())
        {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
        s
      end

    {:ok, t} = Tournaments.open_check_in(admin, t)
    assert t.status == :check_in

    # Sign-ups are refused once check-in is open.
    late = Scope.for_user(user_fixture())

    assert {:error, :registration_closed} =
             Tournaments.register(late, t.id, %{"decklist_url" => valid_fabrary_url()})

    # Only two of three players check in.
    assert {:ok, _} = Tournaments.check_in(s1, t.id)
    assert {:ok, _} = Tournaments.check_in(s2, t.id)

    {:ok, t} = Tournaments.start_tournament(admin, t)
    assert t.status == :swiss

    # The player who didn't check in is dropped and not paired.
    assert Tournaments.get_registration(t.id, s3.user.id).dropped_at

    paired_ids =
      t.current_round_id
      |> Tournaments.list_matches_for_round()
      |> Enum.flat_map(fn m -> [m.player1_id, m.player2_id] end)
      |> Enum.reject(&is_nil/1)

    assert s1.user.id in paired_ids
    assert s2.user.id in paired_ids
    refute s3.user.id in paired_ids
  end

  test "open_check_in requires at least 2 registered players", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    # No players yet.
    assert {:error, :not_enough_players} = Tournaments.open_check_in(admin, t)

    # One player is still not enough.
    s = Scope.for_user(user_fixture())
    {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
    assert {:error, :not_enough_players} = Tournaments.open_check_in(admin, t)

    # Two players unlocks check-in.
    s2 = Scope.for_user(user_fixture())
    {:ok, _} = Tournaments.register(s2, t.id, %{"decklist_url" => valid_fabrary_url()})
    assert {:ok, t} = Tournaments.open_check_in(admin, t)
    assert t.status == :check_in
  end

  test "start_tournament requires the check-in phase to be open", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    for _ <- 1..2 do
      s = Scope.for_user(user_fixture())
      {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
    end

    assert {:error, :wrong_status} = Tournaments.start_tournament(admin, t)
  end

  test "cannot start until the check-in minimum has elapsed", %{admin_scope: admin} do
    Application.put_env(:tabletop, :check_in_min_seconds, 300)
    on_exit(fn -> Application.put_env(:tabletop, :check_in_min_seconds, 0) end)

    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    scopes =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())
        {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
        s
      end

    {:ok, t} = Tournaments.open_check_in(admin, t)
    for s <- scopes, do: {:ok, _} = Tournaments.check_in(s, t.id)

    assert {:error, :check_in_too_soon} = Tournaments.start_tournament(admin, t)

    # Simulate the window having opened five minutes ago.
    past = DateTime.add(DateTime.utc_now(), -301, :second)

    {:ok, t} =
      t
      |> Tabletop.Tournaments.Tournament.status_changeset(%{check_in_opened_at: past})
      |> Tabletop.Repo.update()

    assert {:ok, t} = Tournaments.start_tournament(admin, t)
    assert t.status == :swiss
  end

  test "start is gated on the scheduled start time", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin, params: %{"starts_at" => "2099-01-01T00:00:00Z"})
    {:ok, t} = Tournaments.open_registration(admin, t)

    scopes =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())
        {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
        s
      end

    {:ok, t} = Tournaments.open_check_in(admin, t)
    for s <- scopes, do: {:ok, _} = Tournaments.check_in(s, t.id)

    # Check-in is satisfied but the scheduled start hasn't arrived.
    assert {:error, :before_start_time} = Tournaments.start_tournament(admin, t)

    # Once the scheduled start passes, it can begin.
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, t} = t |> Ecto.Changeset.change(starts_at: past) |> Tabletop.Repo.update()

    assert {:ok, t} = Tournaments.start_tournament(admin, t)
    assert t.status == :swiss
  end

  test "check_in is rejected outside the check-in phase", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, _} = Tournaments.open_registration(admin, t)
    s = Scope.for_user(user_fixture())
    {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})

    assert {:error, :check_in_closed} = Tournaments.check_in(s, t.id)
  end

  test "player_action_items surfaces check-in then match prompts", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    [s1, s2] =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())
        {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
        s
      end

    assert Tournaments.player_action_items(nil) == []
    assert Tournaments.player_action_items(s1.user.id) == []

    {:ok, t} = Tournaments.open_check_in(admin, t)
    assert [%{type: :check_in, tournament_id: tid}] = Tournaments.player_action_items(s1.user.id)
    assert tid == t.id

    for s <- [s1, s2], do: {:ok, _} = Tournaments.check_in(s, t.id)
    # Once checked in, the check-in prompt clears.
    assert Tournaments.player_action_items(s1.user.id) == []

    {:ok, _} = Tournaments.start_tournament(admin, t)
    assert [%{type: :match, path: "/games/" <> _}] = Tournaments.player_action_items(s1.user.id)

    # Once a result is entered for the match, the prompt clears for both players
    # (the game is done — no longer surfaced on the home banner).
    match = Tournaments.current_match_for_user(t.id, s1.user.id)
    {:ok, _} = Tournaments.report_result(s1, match.id, "p1_win")
    assert Tournaments.player_action_items(s1.user.id) == []
    assert Tournaments.player_action_items(s2.user.id) == []
  end

  test "players receive notifications for check-in and new matches", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    [s1, s2] =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())
        {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
        s
      end

    Tournaments.subscribe_user_notifications(s1.user.id)

    {:ok, t} = Tournaments.open_check_in(admin, t)
    assert_receive {:user_notification, %{type: :check_in, tournament_id: tid}}
    assert tid == t.id

    for s <- [s1, s2], do: {:ok, _} = Tournaments.check_in(s, t.id)
    {:ok, _} = Tournaments.start_tournament(admin, t)

    assert_receive {:user_notification, %{type: :match, tournament_id: ^tid}}
  end

  test "result reports and confirmation notify the right players", %{admin_scope: admin} do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    [s1, s2] =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())
        {:ok, _} = Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})
        s
      end

    {:ok, t} = Tournaments.open_check_in(admin, t)
    for s <- [s1, s2], do: {:ok, _} = Tournaments.check_in(s, t.id)
    {:ok, t} = Tournaments.start_tournament(admin, t)
    [match] = Tournaments.list_matches_for_round(t.current_round_id)
    report = if match.player1_id == s1.user.id, do: "p1_win", else: "p2_win"

    Tournaments.subscribe_user_notifications(s1.user.id)
    Tournaments.subscribe_user_notifications(s2.user.id)

    # A player's report notifies only the opponent (one message, not two).
    {:ok, _} = Tournaments.report_result(s1, match.id, report)
    assert_receive {:user_notification, %{type: :result, tournament_id: tid}}
    assert tid == t.id
    refute_receive {:user_notification, %{type: :result}}, 50

    # The admin confirming notifies both players.
    {:ok, _} = Tournaments.report_result(s2, match.id, report)
    assert_receive {:user_notification, %{type: :result}}
    {:ok, _} = Tournaments.confirm_match(admin, match.id)
    assert_receive {:user_notification, %{type: :result}}
    assert_receive {:user_notification, %{type: :result}}
  end

  describe "list_recent_winners/1" do
    test "returns finished tournaments newest-first with the winner preloaded",
         %{admin_scope: admin} do
      assert Tournaments.list_recent_winners() == []

      {older, champ_old} = finished_tournament_fixture(admin)
      {newer, champ_new} = finished_tournament_fixture(admin)

      # `updated_at` has second precision, so two tournaments finished in the
      # same test run can tie. Backdate one so finish order is unambiguous.
      set_updated_at(older.id, ~U[2026-06-01 00:00:00Z])
      set_updated_at(newer.id, ~U[2026-06-10 00:00:00Z])

      assert [first, second] = Tournaments.list_recent_winners()

      assert first.id == newer.id
      assert first.winner.id == champ_new.id
      assert first.winner.name == champ_new.name

      # The champion's own registration (hero + deck) is attached.
      assert first.winner_hero == "arakni-huntsman"
      assert first.winner_decklist_url == valid_fabrary_url()

      assert second.id == older.id
      assert second.winner.id == champ_old.id
    end

    test "honours the limit and excludes unfinished tournaments", %{admin_scope: admin} do
      for _ <- 1..3, do: finished_tournament_fixture(admin)
      # A still-open tournament must never appear among winners.
      _open = tournament_fixture(scope: admin)

      assert length(Tournaments.list_recent_winners(2)) == 2
    end
  end

  defp set_updated_at(id, %DateTime{} = at) do
    Repo.update_all(
      from(t in Tabletop.Tournaments.Tournament, where: t.id == ^id),
      set: [updated_at: at]
    )
  end
end
