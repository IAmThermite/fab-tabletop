defmodule TabletopWeb.SystemAnnouncements do
  @moduledoc """
  LiveView `on_mount` hook that puts the current site-wide announcement in
  `@system_announcement` and keeps it live.

  Wired into *every* `live_session` in the router, including the anonymous and
  phone-camera ones — a downtime notice is for everybody on the site, not just
  signed-in players.

  Deliberately separate from `TabletopWeb.UserNotifications`: that hook
  delivers per-user tournament events as transient `:info` flashes, which is
  the wrong vehicle here. There is one flash slot per kind, so the two would
  clobber each other, and the flash toast is hardwired to fade after five
  seconds — too short for "the server is going down". Announcements get their
  own assign and their own component instead.

  The layouts decide the presentation: `Layouts.app` renders a persistent
  banner, `Layouts.game` a dismissible toast (the game view is a fullscreen
  video grid with no room for a bar).
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Tabletop.Announcements

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Announcements.subscribe()

    socket =
      socket
      |> assign(:system_announcement_expiry_timer, nil)
      |> attach_hook(:system_announcement, :handle_info, &handle_announcement/2)
      |> put_announcement(Announcements.active(), sound: false)

    {:cont, socket}
  end

  # The broadcast always carries whatever should now be on screen (or `nil`),
  # so this just assigns it. Everything else passes through to the LiveView's
  # own `handle_info`.
  defp handle_announcement({:system_announcement, announcement}, socket) do
    {:halt, put_announcement(socket, announcement, sound: true)}
  end

  # The window closed with nobody writing anything, so no broadcast is coming.
  # Re-read rather than assuming `nil`: an older, longer-running announcement
  # may still be live underneath this one.
  defp handle_announcement({:system_announcement_expired}, socket) do
    {:halt, put_announcement(socket, Announcements.active(), sound: false)}
  end

  defp handle_announcement(_message, socket), do: {:cont, socket}

  defp put_announcement(socket, announcement, opts) do
    socket
    |> assign(:system_announcement, announcement)
    |> schedule_expiry(announcement)
    |> maybe_play_sound(announcement, Keyword.fetch!(opts, :sound))
  end

  # `ends_at` is otherwise only enforced on mount, so an announcement set to
  # run for an hour would sit on the screen of everyone already connected until
  # something unrelated re-rendered them. One timer per connected LiveView, re-armed
  # whenever the announcement changes — no global scheduler, and nothing fires
  # for open-ended announcements.
  defp schedule_expiry(socket, announcement) do
    cancel_expiry(socket.assigns[:system_announcement_expiry_timer])

    timer =
      with true <- connected?(socket),
           %{ends_at: %DateTime{} = ends_at} <- announcement,
           remaining when remaining > 0 <-
             DateTime.diff(ends_at, DateTime.utc_now(), :millisecond) do
        # +1ms is load-bearing: `diff/3` truncates the sub-millisecond
        # remainder, so firing at exactly `remaining` can land a hair *before*
        # `ends_at`. `active/0` would then hand back the same announcement and
        # the re-armed timer would round to zero — leaving it up forever.
        Process.send_after(self(), {:system_announcement_expired}, remaining + 1)
      else
        _ -> nil
      end

    assign(socket, :system_announcement_expiry_timer, timer)
  end

  defp cancel_expiry(nil), do: :ok
  defp cancel_expiry(timer), do: Process.cancel_timer(timer)

  # Only a *new* announcement chimes — a clear, an expiry, or finding one
  # already up on mount should not. Reuses the `.NotificationSounds` hook in
  # the layout's flash group, which is present on every page.
  defp maybe_play_sound(socket, nil, _sound?), do: socket
  defp maybe_play_sound(socket, _announcement, false), do: socket

  defp maybe_play_sound(socket, _announcement, true) do
    push_event(socket, "play_notification_sound", %{cue: "system_announcement"})
  end
end
