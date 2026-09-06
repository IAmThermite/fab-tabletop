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
    * `:ttl`    — credential lifetime in seconds (default 8h).
    * `:window` — expiry quantisation in seconds (default 1h); see below.

  ## Why the expiry is quantised

  coturn's `user-quota` is keyed on the literal REST username. A naive
  `now + ttl` expiry changes on every call, so each LiveView mount would mint a
  brand-new "user" and the quota would never bind to a real person — one client
  could open allocations without limit.

  Rounding the expiry up to the next `:window` boundary makes the username
  stable for a given user within that window, so the quota applies to the
  person rather than the page load. The cost is that credentials live between
  `ttl` and `ttl + window` seconds rather than exactly `ttl`.

  When TURN isn't configured (e.g. local dev without coturn) only the static
  STUN servers are returned, so signaling still works on permissive networks.
  """

  @stun_servers [
    %{urls: "stun:stun.l.google.com:19302"},
    %{urls: "stun:stun1.l.google.com:19302"}
  ]

  # 8h rather than 24h: the credential ships in a `data-` attribute on the
  # rendered page, so a shorter life limits the blast radius of a leaked page
  # source while still outlasting any realistic session.
  @default_ttl 28_800
  @default_window 3600

  @doc """
  Returns the ICE server list for `user_id`, ready to `Jason.encode!/1` and
  hand to an `RTCPeerConnection`.
  """
  def ice_servers(user_id) do
    config = Application.get_env(:tabletop, __MODULE__, [])
    secret = config[:secret]
    urls = config[:urls] || []

    if is_binary(secret) and secret != "" and urls != [] do
      ttl = config[:ttl] || @default_ttl
      window = config[:window] || @default_window

      @stun_servers ++ [turn_server(urls, secret, ttl, window, user_id)]
    else
      @stun_servers
    end
  end

  defp turn_server(urls, secret, ttl, window, user_id) do
    username = "#{expiry_at(ttl, window)}:#{user_id}"
    credential = Base.encode64(:crypto.mac(:hmac, :sha, secret, username))

    %{urls: urls, username: username, credential: credential}
  end

  # Round the current time up to the next window boundary before adding the
  # ttl, so every call inside a window yields an identical username.
  defp expiry_at(ttl, window) when window > 0 do
    now = System.os_time(:second)
    (div(now, window) + 1) * window + ttl
  end

  defp expiry_at(ttl, _window), do: System.os_time(:second) + ttl
end
