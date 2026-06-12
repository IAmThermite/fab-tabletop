// Card Scanner — click-to-capture card identification from the video feed.
//
// Pipeline: run OpenCV to detect + deskew the card, compute perceptual hashes
// of the art, and send them to the LiveView for a pHash match. Title-bar OCR
// was removed — recognition is pHash-only; users type a name to search instead.

import { imageDataToCanvas } from "./preprocessing"
import { showDebugPanel, showBoundingBox, drawCardBorder, isDebugEnabled } from "./debug"
import { computePhashesForLayout } from "./recognition_pipeline"

const LOG = "[CardScanner]"
const BOX_LINGER_MS = 3000

// Detect region: square so it captures cards in any orientation
const DETECT_RATIO = 0.35

// On a detected-but-unmatched card, retry the pHash match a few times, each
// time growing the deskewed capture region by `REGION_EXPAND_STEP` (so a
// sleeve/border that threw off the detected edges is less likely to matter).
const REGION_EXPAND_STEP = 0.05
const MAX_MATCH_RETRIES = 2

let _worker = null
let _requestCounter = 0

function getWorker() {
  if (_worker) return _worker
  _worker = new Worker("/assets/js/card_scanner/scanner_worker.js")
  _worker.onmessage = (event) => {
    if (event.data.type === "ready") {
      console.log(`${LOG} OpenCV worker ready`)
    } else if (event.data.type === "error") {
      console.warn(`${LOG} OpenCV worker error: ${event.data.message}`)
    }
  }
  return _worker
}

// `regionScale` (default 1) scales the detected card quad outward before the
// deskew, so a retry can pull in a slightly larger region when the first match
// misses (e.g. a sleeve/border threw off the detected edges).
function detectCard(imageData, { regionScale = 1 } = {}) {
  return new Promise((resolve) => {
    const worker = getWorker()
    const requestId = ++_requestCounter

    const timeout = setTimeout(() => {
      worker.removeEventListener("message", handler)
      console.warn(`${LOG} OpenCV detection timed out (req ${requestId})`)
      resolve(null)
    }, 5000)

    const handler = (event) => {
      if (event.data.requestId !== requestId) return

      clearTimeout(timeout)
      worker.removeEventListener("message", handler)

      if (event.data.type === "cardDetected") {
        const { card, cardImageData, quad, layout, originalLayout, art, angle, orientation } = event.data
        if (!card.width || !card.height) { resolve(null); return }
        // Reconstruct ImageData from the transferred buffer
        const cardPixels = new Uint8ClampedArray(cardImageData)
        const deskewedImageData = new ImageData(cardPixels, card.width, card.height)
        resolve({ card, deskewedImageData, quad, layout, originalLayout, art, angle, orientation })
      } else {
        resolve(null)
      }
    }
    worker.addEventListener("message", handler)
    worker.postMessage({ type: "processFrame", imageData, requestId, regionScale })
  })
}

export function preloadScanner() {
  getWorker()
}

/**
 * Attach card-lookup click handling to a game area.
 *
 * @param {object} hook        - The LiveView hook instance (for pushEvent).
 * @param {HTMLCanvasElement} canvasEl  - Canvas to capture from.
 * @param {HTMLElement} gameArea       - Container for loading/toast overlays.
 * @param {object} opts
 * @param {() => boolean} [opts.isFlipped]  - Returns true if video is flipped.
 * @param {() => boolean} [opts.guardFn]    - Returns false to skip the click (e.g. not yet connected).
 */
export function setupCardLookup(hook, canvasEl, gameArea, opts = {}) {
  const isFlipped = opts.isFlipped ?? (() => false)
  const guardFn = opts.guardFn ?? (() => true)

  let _loadingEl = null

  const showLoading = (x, y) => {
    hideLoading()
    const rect = gameArea.getBoundingClientRect()
    _loadingEl = document.createElement("div")
    _loadingEl.className = "absolute z-50 flex items-center gap-2 px-3 py-2 bg-base-200 border border-base-300 rounded-lg shadow-lg text-sm"
    _loadingEl.style.left = (x - rect.left) + "px"
    _loadingEl.style.top = (y - rect.top - 40) + "px"
    _loadingEl.style.transform = "translateX(-50%)"
    _loadingEl.innerHTML = '<span class="loading loading-spinner loading-sm"></span><span>Scanning card...</span>'
    gameArea.appendChild(_loadingEl)
  }

  const hideLoading = () => {
    if (_loadingEl) { _loadingEl.remove(); _loadingEl = null }
  }

  const showToast = (msg) => {
    const toast = document.createElement("div")
    toast.className = "absolute bottom-4 left-1/2 -translate-x-1/2 z-50 px-4 py-2 bg-error text-error-content rounded-lg text-sm shadow-lg"
    toast.textContent = msg
    gameArea.appendChild(toast)
    setTimeout(() => toast.remove(), 3000)
  }

  gameArea.addEventListener("click", async (e) => {
    if (e.target !== canvasEl) return
    if (!guardFn()) return

    showLoading(e.clientX, e.clientY)

    try {
      // Capture the clicked frame once; every retry re-processes these pixels.
      const captured = captureDetectRegion(canvasEl, e.clientX, e.clientY, isFlipped())
      const rect = gameArea.getBoundingClientRect()

      let matched = false
      let lastResult = null
      let matchedScale = null
      const attemptedScales = []

      if (captured) {
        // Retry on a detected-but-unmatched card, growing the deskew region
        // each attempt so a sleeve/border is less likely to throw off the match.
        for (let attempt = 0; attempt <= MAX_MATCH_RETRIES; attempt++) {
          const regionScale = 1 + attempt * REGION_EXPAND_STEP
          attemptedScales.push(regionScale)
          const result = await detectAndHash(captured, regionScale, gameArea, isFlipped(), attempt === 0)
          lastResult = result || lastResult

          const phashes = (result?.phashes || []).map(({ kind, value }) => ({
            kind, value: value.toString(),
          }))

          // No card detected at all — expanding the region won't help.
          if (phashes.length === 0) break

          const payload = {
            x: e.clientX - rect.left + 10,
            y: e.clientY - rect.top - 50,
            phashes,
            region_scale: regionScale,
          }
          if (result.detectedPitch != null) {
            payload.detected_pitch = result.detectedPitch
          }

          matched = await pushOpenCard(hook, payload)
          if (matched) {
            matchedScale = regionScale
            if (attempt > 0) {
              console.log(
                `${LOG} ✓ Matched via expanded capture region: ` +
                `${(regionScale * 100).toFixed(0)}% on retry #${attempt}`,
              )
            }
            break
          }

          if (attempt < MAX_MATCH_RETRIES) {
            console.log(`${LOG} No match at region ${(regionScale * 100).toFixed(0)}% — retrying larger`)
          }
        }
      }

      hideLoading()

      if (!matched && attemptedScales.length > 1) {
        const tried = attemptedScales.map((s) => `${(s * 100).toFixed(0)}%`).join(", ")
        console.log(`${LOG} ✗ No match after trying capture regions: ${tried}`)
      }

      // Always-on confirmation outline around the card OpenCV recognised — uses
      // the final attempted region (so it visibly grows when a retry succeeded
      // via the expanded capture). Skipped only if nothing was ever detected.
      if (captured && lastResult?.quad) {
        fadeBox(drawCardBorder(captured.rect, lastResult.quad, captured, captured.scaleX, captured.scaleY, isFlipped()))
      }

      if (isDebugEnabled() && lastResult) {
        showDebugPanel({ ...lastResult, matchedScale, attemptedScales })
      }
      if (!matched) showToast("Could not detect card, try again.")
    } catch (err) {
      console.error("[CardScanner] detection error:", err)
      hideLoading()
      showToast("Card detection failed. Try again.")
    }
  })
}

function captureRegion(ctx, canvasEl, canvasX, canvasY, w, h) {
  const sx = Math.max(0, Math.round(canvasX - w / 2))
  const sy = Math.max(0, Math.round(canvasY - h / 2))
  const sw = Math.min(w, canvasEl.width - sx)
  const sh = Math.min(h, canvasEl.height - sy)
  if (sw <= 0 || sh <= 0) return null
  return { imageData: ctx.getImageData(sx, sy, sw, sh), sx, sy, sw, sh }
}

// Push `open_card` and resolve with whether the server matched a card. The
// server always replies `{matched: bool}`; a timeout guards against a missing
// reply so the retry loop / spinner can't hang.
function pushOpenCard(hook, payload) {
  return new Promise((resolve) => {
    let settled = false
    const finish = (v) => {
      if (settled) return
      settled = true
      resolve(v)
    }
    const timer = setTimeout(() => finish(false), 4000)
    hook.pushEvent("open_card", payload, (reply) => {
      clearTimeout(timer)
      finish(reply?.matched === true)
    })
  })
}

// Detect pitch color from the colored strip at the top of a deskewed card
// Returns { pitch: 1|2|3, confidence: number } or null if uncertain
function detectPitchColor(imageData, cardW, cardH) {
  const data = imageData.data
  // Sample the pitch strip: Y 1%-4%, X 25%-75% (avoids corners/edges)
  const y0 = Math.round(cardH * 0.01)
  const y1 = Math.round(cardH * 0.04)
  const x0 = Math.round(cardW * 0.25)
  const x1 = Math.round(cardW * 0.75)

  let redVotes = 0, yellowVotes = 0, blueVotes = 0, totalVotes = 0

  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * cardW + x) * 4
      const r = data[i], g = data[i + 1], b = data[i + 2]

      // RGB to HSV
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const delta = max - min
      const v = max / 255
      const s = max === 0 ? 0 : delta / max

      if (s < 0.20 || v < 0.15) continue // Skip neutral/dark pixels

      let h = 0
      if (delta > 0) {
        if (max === r) h = 60 * (((g - b) / delta) % 6)
        else if (max === g) h = 60 * ((b - r) / delta + 2)
        else h = 60 * ((r - g) / delta + 4)
        if (h < 0) h += 360
      }

      totalVotes++
      if (h < 25 || h > 340) redVotes++
      else if (h >= 25 && h <= 65) yellowVotes++
      else if (h >= 190 && h <= 260) blueVotes++
    }
  }

  if (totalVotes === 0) return null

  const redRatio = redVotes / totalVotes
  const yellowRatio = yellowVotes / totalVotes
  const blueRatio = blueVotes / totalVotes

  const threshold = 0.60
  if (redRatio > threshold) return { pitch: 1, confidence: redRatio }
  if (yellowRatio > threshold) return { pitch: 2, confidence: yellowRatio }
  if (blueRatio > threshold) return { pitch: 3, confidence: blueRatio }

  return null
}

function fadeBox(box) {
  setTimeout(() => {
    box.style.opacity = "0"
    setTimeout(() => box.remove(), 500)
  }, BOX_LINGER_MS)
}

// Grab the square region around the click from the current frame. Captured
// once per click so retries re-process the SAME pixels (the video is live and
// would otherwise change between attempts).
export function captureDetectRegion(canvasEl, clientX, clientY, isFlipped) {
  const rect = canvasEl.getBoundingClientRect()
  const scaleX = canvasEl.width / rect.width
  const scaleY = canvasEl.height / rect.height

  let canvasX = (clientX - rect.left) * scaleX
  let canvasY = (clientY - rect.top) * scaleY

  if (isFlipped) {
    canvasX = canvasEl.width - canvasX
    canvasY = canvasEl.height - canvasY
  }

  const ctx = canvasEl.getContext("2d")
  const detectSize = Math.round(Math.min(canvasEl.width, canvasEl.height) * DETECT_RATIO)
  const capture = captureRegion(ctx, canvasEl, canvasX, canvasY, detectSize, detectSize)
  if (!capture) return null

  return { ...capture, rect, scaleX, scaleY }
}

// Detect + deskew the card from an already-captured region and compute its
// pHashes. `regionScale` (default 1) grows the detected quad before deskew so a
// retry can pull in a slightly larger region. `drawBoxes` overlays the detect
// box + card quad (debug); pass true only on the first attempt.
export async function detectAndHash(captured, regionScale, container, isFlipped, drawBoxes) {
  if (drawBoxes && container && isDebugEnabled()) {
    fadeBox(showBoundingBox(
      container, captured.rect,
      captured.sx / captured.scaleX, captured.sy / captured.scaleY,
      captured.sw / captured.scaleX, captured.sh / captured.scaleY,
      isFlipped, "oklch(0.65 0.12 280)", "Detect",
    ))
  }

  const detected = await detectCard(captured.imageData, { regionScale })
  if (!detected) {
    console.log(`${LOG} OpenCV found no card`)
    return null
  }

  const { card, deskewedImageData, quad, layout, originalLayout, art, angle, orientation } = detected

  console.log(`${LOG} Card: ${card.width}x${card.height} (${layout}), angle: ${angle.toFixed(1)}°, region: ${(regionScale * 100).toFixed(0)}%`)

  // Compute all pHashes via the shared pipeline (canvas-free; same module
  // used by the JS recognition test).
  const phashEntries = computePhashesForLayout(deskewedImageData, {
    layout,
    art,
    orientation,
  })

  // Bridge back to canvases for the debug panel — the panel renders via
  // toDataURL which only works on real canvases.
  const phashes = phashEntries.map(({ kind, value, imageData }) => ({
    kind,
    value,
    canvas: imageDataToCanvas(imageData),
  }))

  for (const { kind, value } of phashes) {
    console.log(`${LOG} pHash[${kind}]: ${value}`)
  }

  // Pitch color from the colored strip at the top of the deskewed card.
  const pitchResult = detectPitchColor(deskewedImageData, card.width, card.height)
  if (pitchResult) {
    console.log(`${LOG} Pitch: ${pitchResult.pitch} (confidence: ${(pitchResult.confidence * 100).toFixed(0)}%)`)
  }

  const result = {
    cardCanvas: imageDataToCanvas(deskewedImageData),
    angle,
    orientation,
    layout,
    originalLayout,
    quad,
    phashes,
    detectMethod: phashes.length > 0 ? "card_art" : "none",
  }
  if (pitchResult) {
    result.detectedPitch = pitchResult.pitch
  }

  return result
}
