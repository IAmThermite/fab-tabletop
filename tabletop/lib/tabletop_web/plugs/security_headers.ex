defmodule TabletopWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds security headers (CSP, COOP, Referrer-Policy) on top of Phoenix's
  `put_secure_browser_headers`.

  Source-list notes:
    * `script-src` allows `https://cdn.jsdelivr.net` because the card scanner
      worker (`assets/js/card_scanner/scanner_worker.js`) lazily loads OpenCV.js
      from that CDN via `importScripts`.
    * `'wasm-unsafe-eval'` is required by OpenCV.js (WASM).
    * `connect-src` allows `https:` because OpenCV.js fetches `opencv_js.wasm`
      from the CDN at runtime (`wss:` covers the LiveView / WebRTC sockets).
    * `worker-src 'self' blob:` — tesseract.js spawns its worker from a Blob URL.
    * `style-src` / `font-src` allow Google Fonts (`fonts.googleapis.com` serves
      the stylesheet, `fonts.gstatic.com` serves the woff2 files) — see the
      `<link>` in `root.html.heex`.
    * `img-src` allows the legendstory S3 bucket (card images) and `data:`
      / `blob:` URLs used by canvas captures.
    * COEP is intentionally omitted — the card-image S3 bucket does not send
      `Cross-Origin-Resource-Policy`, so `require-corp` would break every card.
  """

  import Plug.Conn

  @csp [
         "default-src 'self'",
         "img-src 'self' https://*.s3.amazonaws.com https://cdn.jsdelivr.net data: blob:",
         "media-src 'self' blob:",
         "script-src 'self' 'wasm-unsafe-eval' https://cdn.jsdelivr.net",
         "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
         "connect-src 'self' wss: https:",
         "worker-src 'self' blob:",
         "font-src 'self' data: https://fonts.gstatic.com",
         "frame-ancestors 'none'",
         "base-uri 'self'",
         "form-action 'self'"
       ]
       |> Enum.join("; ")

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
  end
end
