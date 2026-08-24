defmodule Tabletop.AnnouncementsFixtures do
  @moduledoc """
  Test helpers for creating `Tabletop.Announcements` entities.

  Inserts straight through the changeset rather than the context so tests can
  place an announcement's window in the past or the future without an admin
  scope — the context's writers are admin-guarded on purpose.
  """
  alias Tabletop.Announcements.Announcement
  alias Tabletop.Repo

  def announcement_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:message, "Scheduled maintenance at 21:00 UTC.")

    %Announcement{}
    |> Announcement.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  An announcement whose window has already closed.
  """
  def expired_announcement_fixture(attrs \\ %{}) do
    now = DateTime.utc_now()

    attrs
    |> Enum.into(%{})
    |> Map.put_new(:starts_at, DateTime.add(now, -120, :minute))
    |> Map.put_new(:ends_at, DateTime.add(now, -60, :minute))
    |> announcement_fixture()
  end

  @doc """
  An announcement scheduled to start later.
  """
  def future_announcement_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.put_new(:starts_at, DateTime.add(DateTime.utc_now(), 60, :minute))
    |> announcement_fixture()
  end
end
