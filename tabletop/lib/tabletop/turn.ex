defmodule Tabletop.Turn do
  @moduledoc """
  Builds the WebRTC ICE server list (STUN + TURN) for clients.

  TURN credentials follow coturn's "TURN REST API" / `use-auth-secret` scheme:
  the server is configured with a shared secret and clients present a
  time-limited HMAC credential, so we never store per-user TURN passwords.

    username   = "<expiry_unix>:<user_id>"
    credential = base64(HMAC-SHA1(secret, username))

  Config (`config :tabletop, Tabletop.Turn, ...`):
    * `:secret` — shared static-auth-secret (must match coturn). `nil` disables TURN.
    * `:urls`   — list of `turn:` / `turns:` URLs. Empty disables TURN.
    * `:ttl`    — credential lifetime in seconds (default 24h).

  When TURN isn't configured (e.g. local dev without coturn) only the static
  STUN servers are returned, so signaling still works on permissive networks.
  """

  @stun_servers [
    %{urls: "stun:stun.l.google.com:19302"},
    %{urls: "stun:stun1.l.google.com:19302"}
  ]

  @default_ttl 86_400

  @doc """
  Returns the ICE server list for `user_id`, ready to `Jason.encode!/1` and
  hand to an `RTCPeerConnection`.
  """
  def ice_servers(user_id) do
    config = Application.get_env(:tabletop, __MODULE__, [])
    secret = config[:secret]
    urls = config[:urls] || []

    if is_binary(secret) and secret != "" and urls != [] do
      @stun_servers ++ [turn_server(urls, secret, config[:ttl] || @default_ttl, user_id)]
    else
      @stun_servers
    end
  end

  defp turn_server(urls, secret, ttl, user_id) do
    expiry = System.os_time(:second) + ttl
    username = "#{expiry}:#{user_id}"
    credential = Base.encode64(:crypto.mac(:hmac, :sha, secret, username))

    %{urls: urls, username: username, credential: credential}
  end
end
