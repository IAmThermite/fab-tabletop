defmodule TabletopWeb.CameraRelayToken do
  @moduledoc """
  Signs and verifies the token behind the phone-as-camera flow.

  The token is embedded in the QR code the desktop shows (`/phone-camera/:token`)
  and is also what the phone's socket connects with. It carries the desktop
  user's id, which both peers use as the `camera_relay:<user_id>` topic key.

  `@max_age` matches the user socket token's 24 h. It cannot be short: the QR is
  rendered inside the `phx-update="ignore"` settings dialog, so it is minted once
  at page render and never refreshed — a shorter life would silently rot the QR
  on any page left open past it (a normal-length game).
  """

  @salt "camera relay"
  @max_age 86_400

  @doc "Signs a relay token for `user_id`. Accepts a conn, socket, or endpoint."
  def sign(context, user_id), do: Phoenix.Token.sign(context, @salt, user_id)

  @doc "Verifies a relay token, returning `{:ok, user_id}` or `{:error, reason}`."
  def verify(context, token), do: Phoenix.Token.verify(context, @salt, token, max_age: @max_age)

  @doc "The `/phone-camera/:token` URL a phone opens to act as `user_id`'s camera."
  def url(context, user_id) do
    "#{TabletopWeb.Endpoint.url()}/phone-camera/#{sign(context, user_id)}"
  end

  @doc "An SVG QR code encoding `url/2`, for the settings dialog."
  def qr_svg(context, user_id) do
    context |> url(user_id) |> EQRCode.encode() |> EQRCode.svg(width: 200)
  end
end
