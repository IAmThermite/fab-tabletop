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
      Tournaments.create_tournament(user_scope, %{"name" => "x", "format" => "classic_constructed"})
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
    {:ok, _} = Tournaments.open_registration(admin, t)

    [s1, s2] =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())

        {:ok, _} =
          Tournaments.register(s, t.id, %{"decklist_url" => valid_fabrary_url()})

        s
      end

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
end
