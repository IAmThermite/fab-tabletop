import * as Sentry from "@sentry/browser"

/**
 * Browser error reporting, into its own Sentry project.
 *
 * Separate from the server's project on purpose: the two have very different
 * noise profiles — an ad-blocker mangling a request or a wedged browser
 * extension, versus a `GameSession` crashing — and keeping them apart means one
 * can be triaged, alerted on and quota-managed without drowning the other.
 * The DSN therefore comes from `SENTRY_FRONTEND_DSN`, not `SENTRY_DSN`.
 *
 * Only errors are collected. Performance tracing and session replay are left
 * out — not merely disabled — so esbuild tree-shakes those integrations out of
 * the bundle entirely. Adding either means importing its integration here and
 * accepting a substantially larger bundle.
 *
 * The DSN comes from a `<meta>` tag rendered by `root.html.heex` rather than
 * being baked in at build time, so one image works across environments. With no
 * DSN the SDK is never initialised at all, which mirrors the server: unset
 * SENTRY_FRONTEND_DSN means silence, with no separate opt-out to remember.
 */
export function initErrorReporting() {
  const dsn = metaContent("sentry-dsn")
  if (!dsn) return false

  Sentry.init({
    dsn,
    environment: metaContent("sentry-environment") || "unknown",

    // Reporting is best-effort telemetry, so it must never be the reason a
    // player's game breaks. Cap the queue and drop rather than retry forever.
    maxBreadcrumbs: 30,

    // Browser noise that is not actionable and would otherwise dominate the
    // issue list. ResizeObserver warnings in particular are emitted by Chrome
    // during ordinary layout and mean nothing here.
    ignoreErrors: [
      "ResizeObserver loop limit exceeded",
      "ResizeObserver loop completed with undelivered notifications",
    ],

    // Extensions inject scripts into the page and their failures surface as our
    // errors. Nothing we serve runs from these schemes.
    denyUrls: [/^chrome-extension:\/\//, /^moz-extension:\/\//, /^safari-extension:\/\//],
  })

  return true
}

/**
 * Reports an error raised inside a Web Worker.
 *
 * Worker errors do not reach the main thread's global handlers, so the card
 * scanner's failures would otherwise be invisible to Sentry even though the
 * scanner is the feature most likely to break on an unfamiliar device. The
 * worker's `onerror` forwards here instead.
 */
export function captureWorkerError(name, event, {uncaught = true} = {}) {
  Sentry.captureException(errorFrom(event), {
    // `uncaught` separates a worker that died from one that caught a problem
    // and reported it — the first is a bug, the second is often just a frame
    // the scanner could not read.
    tags: {source: "worker", worker: name, uncaught: String(uncaught)},
    extra: {filename: event?.filename, lineno: event?.lineno, colno: event?.colno},
  })
}

// `ErrorEvent` carries the original error in `.error`, but it is absent for
// cross-origin failures — fall back to the message so the event still lands.
function errorFrom(event) {
  if (event?.error instanceof Error) return event.error
  return new Error(event?.message || "Unknown worker error")
}

function metaContent(name) {
  const el = document.querySelector(`meta[name='${name}']`)
  const content = el?.getAttribute("content")?.trim()
  return content || null
}
