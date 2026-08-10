defmodule Tabletop.Announcements do
  @moduledoc """
  Site-wide announcements — one banner/toast shown to every visitor, used for
  things like "scheduled maintenance at 21:00 UTC".

  Announcements are persisted rather than merely broadcast. A PubSub broadcast
  alone only reaches sockets connected at that instant, which is the wrong
  semantics for a downtime notice: anyone who loads a page, refreshes, or
  reconnects a minute later would see nothing, and page refreshes are constant
  in this app. So writers do both — persist the row, then broadcast — and
  `TabletopWeb.SystemAnnouncements` reads `active/0` on every mount.

  There is deliberately only ever *one* announcement on screen: every write
  broadcasts `{:system_announcement, active_announcement_or_nil}`, so
  subscribers just assign whatever they are handed instead of reconciling a
  list. Clearing the current one surfaces the next still-active one, if any.
  """
  import Ecto.Query, warn: false

  alias Tabletop.Accounts.Scope
  alias Tabletop.Announcements.Announcement
  alias Tabletop.Repo

  @topic "system_announcements"

  # ─────────── PubSub ───────────

  @doc """
  Subscribes the caller to the site-wide announcement stream. Messages are
  `{:system_announcement, announcement | nil}` carrying the announcement that
  should now be on screen — `nil` when there is nothing to show.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, @topic)
  end

  defp broadcast_active do
    Phoenix.PubSub.broadcast(Tabletop.PubSub, @topic, {:system_announcement, active()})
  end

  # ─────────── Reads ───────────

  @doc """
  The announcement that should currently be on screen, or `nil`.

  Runs on every LiveView mount, so it is a single indexed row lookup: the
  newest announcement whose display window covers `now`.
  """
  def active(now \\ DateTime.utc_now()) do
    from(a in Announcement,
      where: a.starts_at <= ^now,
      where: is_nil(a.ends_at) or a.ends_at > ^now,
      order_by: [desc: a.starts_at, desc: a.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Most recent announcements for the admin page, newest first, including
  expired ones so an admin can see what has been sent.
  """
  def list_announcements(limit \\ 20) do
    from(a in Announcement,
      order_by: [desc: a.starts_at, desc: a.inserted_at],
      limit: ^limit,
      preload: [:created_by]
    )
    |> Repo.all()
  end

  def get_announcement!(id), do: Repo.get!(Announcement, id)

  @doc """
  True while `now` falls inside the announcement's display window.
  """
  def active?(announcement, now \\ DateTime.utc_now())

  def active?(%Announcement{starts_at: starts_at, ends_at: ends_at}, now) do
    DateTime.compare(starts_at, now) != :gt and
      (is_nil(ends_at) or DateTime.compare(ends_at, now) == :gt)
  end

  def active?(nil, _now), do: false

  def change_announcement(%Announcement{} = announcement, attrs \\ %{}, scope \\ nil) do
    Announcement.changeset(announcement, attrs, scope)
  end

  # ─────────── Admin writes ───────────

  def create_announcement(scope, attrs) do
    ensure_admin!(scope)

    %Announcement{}
    |> Announcement.changeset(attrs, scope)
    |> Repo.insert()
    |> broadcast_on_success()
  end

  def update_announcement(scope, %Announcement{} = announcement, attrs) do
    ensure_admin!(scope)

    announcement
    |> Announcement.changeset(attrs, scope)
    |> Repo.update()
    |> broadcast_on_success()
  end

  @doc """
  Takes an announcement off screen by ending its window now. Kept distinct from
  `delete_announcement/2` so the record survives as a log of what was sent.
  """
  def clear_announcement(scope, %Announcement{} = announcement) do
    ensure_admin!(scope)

    announcement
    |> Ecto.Changeset.change(ends_at: DateTime.utc_now())
    |> Repo.update()
    |> broadcast_on_success()
  end

  def delete_announcement(scope, %Announcement{} = announcement) do
    ensure_admin!(scope)

    announcement
    |> Repo.delete()
    |> broadcast_on_success()
  end

  @doc """
  Publishes an announcement without a user scope, for use from a remote
  console:

      Tabletop.Announcements.publish!("Maintenance at 21:00 UTC — games will disconnect.",
        level: :warning, duration_minutes: 60)

  Deliberately unguarded: reaching this function already requires shell access
  to the running release, which outranks any admin list. It exists because
  during an incident the admin UI may be exactly the thing that is unhealthy.

  Options: `:level` (`:info | :warning | :critical`), `:duration_minutes`,
  `:dismissible`, `:starts_at`.
  """
  def publish!(message, opts \\ []) when is_binary(message) do
    attrs =
      opts
      |> Keyword.take([:level, :duration_minutes, :dismissible, :starts_at])
      |> Map.new()
      |> Map.put(:message, message)

    %Announcement{}
    |> Announcement.changeset(attrs)
    |> Repo.insert!()
    |> tap(fn _ -> broadcast_active() end)
  end

  @doc """
  Clears whatever is currently on screen, for use from a remote console. Returns
  the cleared announcement, or `nil` if there was nothing showing.
  """
  def clear! do
    case active() do
      nil ->
        nil

      announcement ->
        announcement
        |> Ecto.Changeset.change(ends_at: DateTime.utc_now())
        |> Repo.update!()
        |> tap(fn _ -> broadcast_active() end)
    end
  end

  # Every successful write re-reads and broadcasts the currently-active
  # announcement, so subscribers never have to work out whether the row they
  # were handed is the one that should be showing.
  defp broadcast_on_success({:ok, _} = result) do
    broadcast_active()
    result
  end

  defp broadcast_on_success(error), do: error

  defp ensure_admin!(scope) do
    unless Scope.admin?(scope), do: raise(Tabletop.NotAdminError)
    :ok
  end
end
