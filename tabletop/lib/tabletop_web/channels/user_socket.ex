defmodule TabletopWeb.UserSocket do
  use Phoenix.Socket

  channel "game:*", TabletopWeb.GameChannel
  channel "camera_relay:*", TabletopWeb.CameraRelayChannel

  # `:socket_kind` records which token authenticated the connection. A camera
  # relay topic is keyed by user id and legitimately holds two of that user's
  # sockets — their desktop and their phone — so it is the only thing telling
  # the two ends apart. See TabletopWeb.CameraRelayChannel.
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(socket, "user socket", token, max_age: 86_400) do
      {:ok, user_id} ->
        {:ok, socket |> assign(:user_id, user_id) |> assign(:socket_kind, :user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(%{"camera_relay_token" => token}, socket, _connect_info) do
    case TabletopWeb.CameraRelayToken.verify(socket, token) do
      {:ok, user_id} ->
        {:ok, socket |> assign(:user_id, user_id) |> assign(:socket_kind, :phone)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
