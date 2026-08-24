defmodule Tabletop.AnnouncementsTest do
  use Tabletop.DataCase, async: false

  import Tabletop.AnnouncementsFixtures
  import Tabletop.TournamentsFixtures, only: [admin_scope_fixture: 0]

  alias Tabletop.Accounts.Scope
  alias Tabletop.Announcements

  describe "active/1" do
    test "is nil when nothing has been published" do
      refute Announcements.active()
    end

    test "returns an announcement with no end time" do
      a = announcement_fixture(message: "Down at 21:00")
      assert %{id: id} = Announcements.active()
      assert id == a.id
    end

    test "ignores one whose window has closed" do
      expired_announcement_fixture()
      refute Announcements.active()
    end

    test "ignores one that has not started yet" do
      future_announcement_fixture()
      refute Announcements.active()
    end

    test "returns the newest when several windows overlap" do
      now = DateTime.utc_now()
      announcement_fixture(message: "older", starts_at: DateTime.add(now, -60, :minute))
      newer = announcement_fixture(message: "newer", starts_at: DateTime.add(now, -1, :minute))

      assert Announcements.active().id == newer.id
    end
  end

  describe "active?/2" do
    test "tracks the window bounds" do
      now = DateTime.utc_now()

      assert Announcements.active?(announcement_fixture())
      refute Announcements.active?(expired_announcement_fixture())
      refute Announcements.active?(future_announcement_fixture())
      refute Announcements.active?(nil)

      ending_soon = announcement_fixture(duration_minutes: 15)
      assert Announcements.active?(ending_soon)
      refute Announcements.active?(ending_soon, DateTime.add(now, 16, :minute))
    end
  end

  describe "create_announcement/2" do
    setup do
      %{admin: admin_scope_fixture()}
    end

    test "requires an admin", %{admin: admin} do
      player = Scope.for_user(Tabletop.AccountsFixtures.user_fixture())

      assert_raise Tabletop.NotAdminError, fn ->
        Announcements.create_announcement(player, %{"message" => "nope"})
      end

      assert_raise Tabletop.NotAdminError, fn ->
        Announcements.create_announcement(nil, %{"message" => "nope"})
      end

      # The admin from the same setup still gets through, so the guard is about
      # the scope and not about the params.
      assert {:ok, _} = Announcements.create_announcement(admin, %{"message" => "yes"})
    end

    test "stamps the creator and defaults the start to now", %{admin: admin} do
      before = DateTime.utc_now()

      assert {:ok, announcement} =
               Announcements.create_announcement(admin, %{"message" => "Maintenance"})

      assert announcement.created_by_id == admin.user.id
      assert announcement.level == :info
      assert announcement.dismissible
      refute announcement.ends_at
      assert DateTime.compare(announcement.starts_at, before) != :lt
    end

    test "derives ends_at from the chosen duration", %{admin: admin} do
      assert {:ok, announcement} =
               Announcements.create_announcement(admin, %{
                 "message" => "Back in an hour",
                 "duration_minutes" => "60"
               })

      assert DateTime.diff(announcement.ends_at, announcement.starts_at, :minute) == 60
    end

    test "a blank duration means no end time", %{admin: admin} do
      assert {:ok, announcement} =
               Announcements.create_announcement(admin, %{
                 "message" => "Until further notice",
                 "duration_minutes" => ""
               })

      refute announcement.ends_at
    end

    test "rejects a blank message", %{admin: admin} do
      assert {:error, changeset} = Announcements.create_announcement(admin, %{"message" => ""})
      assert %{message: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an end time that precedes the start", %{admin: admin} do
      now = DateTime.utc_now()

      assert {:error, changeset} =
               Announcements.create_announcement(admin, %{
                 "message" => "Backwards",
                 "starts_at" => now,
                 "ends_at" => DateTime.add(now, -5, :minute)
               })

      assert %{ends_at: ["must be after the start time"]} = errors_on(changeset)
    end

    test "broadcasts the announcement to subscribers", %{admin: admin} do
      Announcements.subscribe()

      {:ok, announcement} = Announcements.create_announcement(admin, %{"message" => "Heads up"})

      assert_receive {:system_announcement, broadcast}
      assert broadcast.id == announcement.id
    end

    test "a failed write broadcasts nothing", %{admin: admin} do
      Announcements.subscribe()

      assert {:error, _} = Announcements.create_announcement(admin, %{"message" => ""})
      refute_receive {:system_announcement, _}
    end
  end

  describe "clear_announcement/2" do
    setup do
      %{admin: admin_scope_fixture()}
    end

    test "takes it off screen without deleting the record", %{admin: admin} do
      announcement = announcement_fixture()

      assert {:ok, cleared} = Announcements.clear_announcement(admin, announcement)

      refute Announcements.active()
      assert cleared.ends_at
      assert Announcements.get_announcement!(announcement.id)
    end

    test "reveals the next still-active announcement", %{admin: admin} do
      now = DateTime.utc_now()
      older = announcement_fixture(message: "older", starts_at: DateTime.add(now, -60, :minute))
      newer = announcement_fixture(message: "newer", starts_at: DateTime.add(now, -1, :minute))

      Announcements.subscribe()
      {:ok, _} = Announcements.clear_announcement(admin, newer)

      assert_receive {:system_announcement, broadcast}
      assert broadcast.id == older.id
    end

    test "broadcasts nil when nothing is left", %{admin: admin} do
      announcement = announcement_fixture()

      Announcements.subscribe()
      {:ok, _} = Announcements.clear_announcement(admin, announcement)

      assert_receive {:system_announcement, nil}
    end

    test "requires an admin" do
      announcement = announcement_fixture()
      player = Scope.for_user(Tabletop.AccountsFixtures.user_fixture())

      assert_raise Tabletop.NotAdminError, fn ->
        Announcements.clear_announcement(player, announcement)
      end
    end
  end

  describe "delete_announcement/2" do
    test "removes the record and broadcasts" do
      admin = admin_scope_fixture()
      announcement = announcement_fixture()

      Announcements.subscribe()
      assert {:ok, _} = Announcements.delete_announcement(admin, announcement)

      assert_receive {:system_announcement, nil}
      refute Announcements.active()
    end
  end

  describe "list_announcements/1" do
    test "returns expired announcements too, newest first" do
      now = DateTime.utc_now()
      expired_announcement_fixture(message: "old news")

      current =
        announcement_fixture(message: "current", starts_at: DateTime.add(now, -1, :minute))

      assert [first, second] = Announcements.list_announcements()
      assert first.id == current.id
      assert second.message == "old news"
    end
  end

  describe "publish!/2 and clear!/0" do
    test "publish! works without a scope and broadcasts" do
      Announcements.subscribe()

      announcement =
        Announcements.publish!("Emergency restart in 5 minutes",
          level: :critical,
          duration_minutes: 30,
          dismissible: false
        )

      assert announcement.level == :critical
      refute announcement.dismissible
      refute announcement.created_by_id
      assert DateTime.diff(announcement.ends_at, announcement.starts_at, :minute) == 30

      assert_receive {:system_announcement, broadcast}
      assert broadcast.id == announcement.id
    end

    test "clear! ends the active announcement" do
      announcement = announcement_fixture()

      Announcements.subscribe()
      cleared = Announcements.clear!()

      assert cleared.id == announcement.id
      assert_receive {:system_announcement, nil}
      refute Announcements.active()
    end

    test "clear! is a no-op when nothing is showing" do
      Announcements.subscribe()

      refute Announcements.clear!()
      refute_receive {:system_announcement, _}
    end
  end
end
