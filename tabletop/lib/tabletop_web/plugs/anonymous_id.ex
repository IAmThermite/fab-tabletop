defmodule TabletopWeb.Plugs.AnonymousId do
  @moduledoc """
  Ensures every browser session carries a stable `"anon_id"`.

  Anonymous visitors still need a durable identity for anything keyed by user —
  today that is the phone-camera relay topic (`camera_relay:<user_id>`), where
  the desktop and the phone must agree on the same key or they never see each
  other.

  This has to live in the session rather than being generated in `mount/3`: a
  LiveView mounts twice (the dead HTTP render, then the connected websocket
  render), so an id minted in `mount/3` differs between the two. That is not
  academic — the QR code is rendered inside the `phx-update="ignore"` settings
  dialog, so what the user actually scans comes from the *dead* render while the
  JS hook reads the *connected* render's id.
  """

  import Plug.Conn

  @session_key "anon_id"

  @doc "The session key holding the anonymous id."
  def session_key, do: @session_key

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      nil -> put_session(conn, @session_key, generate())
      _existing -> conn
    end
  end

  @doc """
  Builds a new anonymous id.

  The `anon:` prefix keeps these distinguishable from real (UUID) user ids.
  """
  def generate, do: "anon:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
