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

  # A notification raises a toast and refreshes the banner list; everything else
  # passes through untouched to the LiveView's own `handle_info`.
  defp handle_notification({:user_notification, payload}, socket) do
    {:halt,
     socket
     |> put_flash(:info, payload.message)
     |> assign(:notification_items, items_for(current_user_id(socket)))}
  end

  defp handle_notification(_message, socket), do: {:cont, socket}

  defp items_for(nil), do: []
  defp items_for(user_id), do: Tournaments.player_action_items(user_id)

  defp current_user_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} -> id
      _ -> nil
    end
  end
end
