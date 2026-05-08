// Card Scanner — click-to-capture OCR for identifying cards in video feed
//
// Pipeline:
// 1. Run OpenCV to detect the card, extract title for OCR and art for pHash
// 2. If OpenCV fails, fall back to a small fixed-region OCR around the click

import { preprocessForOCR, cropMargins, imageDataToCanvas } from "./preprocessing"
import { preloadOCR, runOCR } from "./ocr"
import { showDebugPanel, showBoundingBox, showCardQuad, isDebugEnabled } from "./debug"
import { computePhashesForLayout, rotated180ImageData } from "./recognition_pipeline"

const LOG = "[CardScanner]"
const BOX_LINGER_MS = 3000

// Detect region: square so it captures cards in any orientation
const DETECT_RATIO = 0.35

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

function detectCard(imageData) {
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
        const { card, cardImageData, quad, layout, title, art, angle, orientation } = event.data
        if (!card.width || !card.height) { resolve(null); return }
        // Reconstruct ImageData from the transferred buffer
        const cardPixels = new Uint8ClampedArray(cardImageData)
        const deskewedImageData = new ImageData(cardPixels, card.width, card.height)
        resolve({ card, deskewedImageData, quad, layout, title, art, angle, orientation })
      } else {
        resolve(null)
      }
    }
    worker.addEventListener("message", handler)
    worker.postMessage({ type: "processFrame", imageData, requestId })
  })
}

export function preloadTesseract() {
  preloadOCR()
  getWorker()
}

/**
 * Attach card-lookup click handling to a game area.
 *
 * @param {object} hook        - The LiveView hook instance (for pushEvent).
 * @param {HTMLCanvasElement} canvasEl  - Canvas to OCR from.
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
      const result = await captureAndOCR(
        canvasEl, e.clientX, e.clientY, isFlipped(),
        gameArea
      )
      hideLoading()

      if (result) {
        const rect = gameArea.getBoundingClientRect()

        const ocrCandidates = [
          { label: "gray", text: result.grayText, confidence: result.grayConfidence },
          { label: "upGray", text: result.upGrayText, confidence: result.upGrayConfidence },
          { label: "sharpThresh", text: result.sharpThreshText, confidence: result.sharpThreshConfidence },
          { label: "thresh", text: result.threshText, confidence: result.threshConfidence },
        ].filter(c => c.confidence > 40 && c.text && c.text.replace(/[^a-zA-Z]/g, "").length >= 3)

        const payload = {
          ocr_candidates: ocrCandidates,
          x: e.clientX - rect.left + 10,
          y: e.clientY - rect.top - 50,
        }

        const phashes = (result.phashes || []).map(({ kind, value }) => ({
          kind, value: value.toString(),
        }))

        if (phashes.length > 0) {
          payload.phashes = phashes
        }

        if (result.detectedPitch != null) {
          payload.detected_pitch = result.detectedPitch
        }

        if (ocrCandidates.length > 0 || phashes.length > 0) {
          hook.pushEvent("open_card", payload)
        } else {
          showToast("Could not detect card, try again.")
        }
      } else {
        showToast("Could not detect card, try again.")
      }
    } catch (err) {
      console.error("[CardLookup] OCR error:", err)
      hideLoading()
      showToast("OCR failed. Try again.")
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

async function processAndOCR(imageData) {
  const { processedCanvas, rawCanvas, grayCanvas, upGrayCanvas, sharpThreshCanvas } = preprocessForOCR(imageData)

  const [grayResult, upGrayResult, sharpThreshResult, threshResult] = await Promise.all([
    runOCR(cropMargins(grayCanvas)),
    runOCR(cropMargins(upGrayCanvas)),
    runOCR(cropMargins(sharpThreshCanvas)),
    runOCR(cropMargins(processedCanvas)),
  ])

  console.log(`${LOG} Grayscale OCR: "${grayResult.text}" (${grayResult.confidence})`)
  console.log(`${LOG} Upscaled gray OCR: "${upGrayResult.text}" (${upGrayResult.confidence})`)
  console.log(`${LOG} Sharp+thresh OCR: "${sharpThreshResult.text}" (${sharpThreshResult.confidence})`)
  console.log(`${LOG} Threshold OCR: "${threshResult.text}" (${threshResult.confidence})`)

  const candidates = [
    { label: "gray", result: grayResult },
    { label: "upGray", result: upGrayResult },
    { label: "sharpThresh", result: sharpThreshResult },
    { label: "thresh", result: threshResult },
  ]
  const best = candidates.reduce((a, b) => a.result.confidence > b.result.confidence ? a : b)
  console.log(`${LOG} Best: ${best.label} (${best.result.confidence})`)

  return {
    ...best.result,
    rawCanvas, grayCanvas, upGrayCanvas, sharpThreshCanvas, processedCanvas,
    grayConfidence: grayResult.confidence,
    grayText: grayResult.text,
    upGrayConfidence: upGrayResult.confidence,
    upGrayText: upGrayResult.text,
    sharpThreshConfidence: sharpThreshResult.confidence,
    sharpThreshText: sharpThreshResult.text,
    threshConfidence: threshResult.confidence,
    threshText: threshResult.text,
  }
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

export async function captureAndOCR(canvasEl, clientX, clientY, isFlipped, container) {
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
  let result = null

  // --- Step 1: OpenCV card detection ---
  const detectSize = Math.round(Math.min(canvasEl.width, canvasEl.height) * DETECT_RATIO)
  // yBias 0.3: click assumed on card art
  const detectCapture = captureRegion(ctx, canvasEl, canvasX, canvasY, detectSize, detectSize)

  if (detectCapture) {
    if (container && isDebugEnabled()) {
      fadeBox(showBoundingBox(
        container, rect,
        detectCapture.sx / scaleX, detectCapture.sy / scaleY,
        detectCapture.sw / scaleX, detectCapture.sh / scaleY,
        isFlipped, "oklch(0.65 0.12 280)", "Detect",
      ))
    }

    const detected = await detectCard(detectCapture.imageData)

    if (detected) {
      const { card, deskewedImageData, quad, layout, title, art, angle, orientation } = detected

      if (container && isDebugEnabled() && quad) {
        fadeBox(showCardQuad(rect, quad, detectCapture, scaleX, scaleY, isFlipped))
      }

      console.log(`${LOG} Card: ${card.width}x${card.height} (${layout}), angle: ${angle.toFixed(1)}°`)

      // Title-bar OCR (vertical only). Operates on canvas-derived ImageData
      // since processAndOCR consumes the duck-type fine.
      const cardCanvas = imageDataToCanvas(deskewedImageData)
      const cardCtx = cardCanvas.getContext("2d")

      let titleImageData = null

      if (layout === "vertical" && title) {
        const tw = Math.min(title.width, card.width - title.x)
        const th = Math.min(title.height, card.height - title.y)
        if (tw > 10 && th > 5) {
          titleImageData = cardCtx.getImageData(title.x, title.y, tw, th)
          result = await processAndOCR(titleImageData)
          result.detectMethod = "title_bar"
          console.log(`${LOG} Title OCR: "${result.text}" (${result.confidence})`)

          if (orientation === "uncertain" && result.confidence < 40) {
            console.log(`${LOG} Low OCR confidence with uncertain orientation — trying flipped title`)
            const flippedTitleY = card.height - title.y - th
            if (flippedTitleY >= 0) {
              const flippedTitleData = rotated180ImageData(
                cardCtx.getImageData(title.x, flippedTitleY, tw, th),
              )
              const flippedResult = await processAndOCR(flippedTitleData)
              console.log(`${LOG} Flipped title OCR: "${flippedResult.text}" (${flippedResult.confidence})`)
              if (flippedResult.confidence > result.confidence) {
                result = flippedResult
                result.detectMethod = "title_bar (flipped)"
                titleImageData = flippedTitleData
              }
            }
          }
        }
      }

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

      // Pitch color detection only valid for vertical layouts.
      let pitchResult = null
      if (layout === "vertical") {
        pitchResult = detectPitchColor(deskewedImageData, card.width, card.height)
        if (pitchResult) {
          console.log(`${LOG} Pitch: ${pitchResult.pitch} (confidence: ${(pitchResult.confidence * 100).toFixed(0)}%)`)
        }
      }

      if (!result) {
        result = { text: "", confidence: 0, detectMethod: phashes.length > 0 ? "card_art" : "none" }
      } else if (phashes.length > 0 && result.detectMethod === "title_bar") {
        result.detectMethod = "title_bar + card_art"
      }

      result.cardCanvas = cardCanvas
      result.angle = angle
      result.orientation = orientation
      result.layout = layout
      result.phashes = phashes
      if (titleImageData) {
        result.titleCanvas = imageDataToCanvas(titleImageData)
      }
      if (pitchResult) {
        result.detectedPitch = pitchResult.pitch
      }
    } else {
      console.log(`${LOG} OpenCV found no card`)
    }
  }

  if (!result) return null

  if (isDebugEnabled()) showDebugPanel(result)

  return result
}
