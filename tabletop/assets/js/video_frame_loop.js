// If `currentTime` hasn't moved in this long while the element is still
// playing with data buffered, stop trusting it as a frame clock (see below).
// Far longer than any real frame interval, so a slow camera isn't mistaken for
// a broken clock.
const STALL_GRACE_MS = 1000

/**
 * Runs `render` at most once per *source* video frame.
 *
 * A bare requestAnimationFrame loop fires at the display refresh rate — 120Hz
 * on current Macs — so it re-draws each frame of a 30fps stream four times
 * over. That waste is not free: it competes with the video encoder, and an
 * encoder short on CPU responds by degrading the picture the opponent sees. So
 * the point here is to skip the redundant draws.
 *
 * Deliberately rAF-plus-dedupe rather than `requestVideoFrameCallback`: rVFC is
 * driven by frame *presentation*, and several of these loops read from a
 * `display: none` video element (the hidden `#local-video` feeding the preview
 * canvases and the outbound transform, and the phone's offscreen rotation
 * source), which is never composited. `currentTime` advances per frame on a
 * playing MediaStream-backed element whether or not it is on screen, so
 * comparing it gives the same once-per-frame cadence with no dependency on the
 * element being rendered.
 *
 * That last claim is an engine detail rather than a guarantee, and the cost of
 * being wrong about it is a permanently frozen preview or — worse — a frozen
 * outbound stream. So it is verified rather than trusted: if the clock stops
 * advancing while the element is still playing, the loop falls back to drawing
 * on every tick. That is merely the old, wasteful behaviour, never a stall.
 *
 * The readyState guard every caller used to carry lives here too.
 *
 * @param {HTMLVideoElement} videoEl - Source whose frame clock drives the loop.
 * @param {() => void} render        - Called once per new frame.
 * @returns {() => void} Stop function; safe to call more than once.
 */
export function startVideoFrameLoop(videoEl, render) {
  let handle = null
  let stopped = false
  let lastTime = -1
  let lastAdvanceAt = 0
  let trustFrameClock = true

  const step = () => {
    handle = null
    if (stopped) return

    if (videoEl.readyState >= videoEl.HAVE_CURRENT_DATA) {
      if (videoEl.currentTime !== lastTime) {
        lastTime = videoEl.currentTime
        lastAdvanceAt = performance.now()
        trustFrameClock = true
        render()
      } else if (!trustFrameClock) {
        render()
      } else if (
        !videoEl.paused &&
        performance.now() - lastAdvanceAt > STALL_GRACE_MS
      ) {
        trustFrameClock = false
        render()
      }
    }

    handle = requestAnimationFrame(step)
  }

  handle = requestAnimationFrame(step)

  return () => {
    stopped = true
    if (handle !== null) cancelAnimationFrame(handle)
    handle = null
  }
}
