defmodule TabletopWeb.UserNotifications do
  @moduledoc """
  LiveView `on_mount` hook that delivers per-user tournament notifications.

  Wired into the current-user/authenticated `live_session`s in the router, so a
  player sees a toast (and a refreshed `@notification_items` banner list) on
  whatever page they happen to be on when check-in opens, a new match is
  generated, the tournament finishes, etc.

  It is the sole subscriber to the user's notification topic — pages should read
  `@notification_items` rather than subscribing again (that would double-deliver).
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Tabletop.Tournaments

  def on_mount(:default, _params, _session, socket) do
    user_id = current_user_id(socket)

    if connected?(socket) and user_id do
      Tournaments.subscribe_user_notifications(user_id)
    end

    socket =
      socket
      |> assign(:notification_items, items_for(user_id))
      |> attach_hook(:user_notifications, :handle_info, &handle_notification/2)

    {:cont, socket}
  end

  # A notification raises a toast, plays its audio cue, and refreshes the banner
  # list; everything else passes through untouched to the LiveView's own
  # `handle_info`.
  defp handle_notification({:user_notification, payload}, socket) do
    {:halt,
     socket
     |> put_flash(:info, payload.message)
     |> assign(:notification_items, items_for(current_user_id(socket)))
     |> maybe_play_sound(payload)}
  end

  defp handle_notification(_message, socket), do: {:cont, socket}

  # The `.NotificationSounds` hook (in the layout's flash group) catches this and
  # plays the cue through the shared sound engine. Unknown types stay silent.
  defp maybe_play_sound(socket, payload) do
    case sound_for(payload[:type]) do
      nil -> socket
      cue -> push_event(socket, "play_notification_sound", %{cue: cue})
    end
  end

  defp sound_for(:check_in), do: "tournament_check_in"
  defp sound_for(:match), do: "tournament_match_ready"
  defp sound_for(:bye), do: "tournament_match_ready"
  defp sound_for(:result), do: "tournament_result"
  defp sound_for(:finished), do: "tournament_finished"
  defp sound_for(_), do: nil

  defp items_for(nil), do: []
  defp items_for(user_id), do: Tournaments.player_action_items(user_id)

  defp current_user_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} -> id
      _ -> nil
    end
  end
end
