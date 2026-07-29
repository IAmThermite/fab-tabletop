defmodule TabletopWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds security headers (CSP, COOP, Referrer-Policy) on top of Phoenix's
  `put_secure_browser_headers`.

  Source-list notes:
    * `script-src` allows `https://cdn.jsdelivr.net` because the card scanner
      worker (`assets/js/card_scanner/scanner_worker.js`) lazily loads OpenCV.js
      from that CDN via `importScripts`.
    * `script-src` also carries a per-request `'nonce-<...>'` (built in `call/2`)
      so the inline theme bootstrap `<script>` in `root.html.heex` can run
      without resorting to `'unsafe-inline'`. The nonce is exposed to the layout
      as the `:csp_nonce` assign.
    * `'wasm-unsafe-eval'` is required by OpenCV.js (WASM).
    * `connect-src` allows `https:` because OpenCV.js fetches `opencv_js.wasm`
      from the CDN at runtime (`wss:` covers the LiveView / WebRTC sockets).
    * `worker-src 'self' blob:` — the card scanner worker is served from
      `/assets` (same-origin); `blob:` covers bundler-inlined workers.
    * `style-src` / `font-src` allow Google Fonts (`fonts.googleapis.com` serves
      the stylesheet, `fonts.gstatic.com` serves the woff2 files) — see the
      `<link>` in `root.html.heex`.
    * `img-src` allows `data:` / `blob:` (canvas captures) plus every host the
      card data set serves card images from — see `@card_image_sources`.
    * COEP is intentionally omitted — the card-image hosts do not send
      `Cross-Origin-Resource-Policy`, so `require-corp` would break every card.
  """

  import Plug.Conn

  # Every host `card_prints.image_url` can point at. Sourced from the
  # `flesh-and-blood-cards` data set (`json/english/card.json`, the
  # `printings[].image_url` field) — a card image served from a host that is not
  # listed here is blocked by the browser and renders as a broken image.
  #
  # Bumping the card submodule can introduce a new host: re-run
  # `test/tabletop_web/plugs/security_headers_test.exs`, which diffs this list
  # against the vendored data set, and extend it if the test fails.
  #
  # `storage.googleapis.com` is a shared, multi-tenant host, so it is narrowed to
  # the bucket the data set actually uses rather than allowed wholesale. The rest
  # are dedicated card-image hosts and are allowed at host level.
  @card_image_sources [
    "https://storage.googleapis.com/fabmaster/",
    "https://legendstory-production-s3-public.s3.amazonaws.com",
    "https://d2wlb52bya4y8z.cloudfront.net",
    "https://dhhim4ltzu1pj.cloudfront.net",
    "https://cdn.fabtcg.com"
  ]

  @doc """
  The card-image hosts allowed by `img-src`, as CSP source expressions.
  """
  def card_image_sources, do: @card_image_sources

  # Directives shared by every response. `script-src` is built per-request in
  # call/2 instead, because it carries a one-time nonce (see @moduledoc).
  @base_directives [
    "default-src 'self'",
    "img-src " <> Enum.join(["'self'", "data:", "blob:" | @card_image_sources], " "),
    "media-src 'self' blob:",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "connect-src 'self' wss: https:",
    "worker-src 'self' blob:",
    "font-src 'self' data: https://fonts.gstatic.com",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    script_src = "script-src 'self' 'wasm-unsafe-eval' https://cdn.jsdelivr.net 'nonce-#{nonce}'"
    csp = Enum.join([script_src | @base_directives], "; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
  end
end
