// Card Scanner — click-to-capture OCR for identifying cards in video feed
//
// Pipeline:
// 1. Run OpenCV to detect the card, extract title for OCR and art for pHash
// 2. If OpenCV fails, fall back to a small fixed-region OCR around the click

import { preprocessForOCR, cropMargins, imageDataToCanvas } from "./preprocessing"
import { preloadOCR, runOCR } from "./ocr"
import { showDebugPanel, showBoundingBox, showCardQuad, isDebugEnabled } from "./debug"
import { computePHash } from "./p_hash"

const LOG = "[CardScanner]"
const BOX_LINGER_MS = 3000

// Detect region: enough to contain one portrait card with margin
const DETECT_W_RATIO = 0.15
const DETECT_H_RATIO = 0.30

// Fallback OCR region: small strip assuming click is on card title center
const FALLBACK_W_RATIO = 0.10
const FALLBACK_H_RATIO = 0.03

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
        const { card, cardImageData, quad, title, art, angle } = event.data
        // Reconstruct ImageData from the transferred buffer
        const cardPixels = new Uint8ClampedArray(cardImageData)
        const deskewedImageData = new ImageData(cardPixels, card.width, card.height)
        resolve({ card, deskewedImageData, quad, title, art, angle })
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
        ].filter(c => c.confidence > 40 && c.text)

        const payload = {
          ocr_candidates: ocrCandidates,
          x: e.clientX - rect.left + 10,
          y: e.clientY - rect.top - 50,
        }

        if (result.artHash != null) {
          payload.phash = result.artHash.toString()
        }

        if (result.detectedPitch != null) {
          payload.detected_pitch = result.detectedPitch
        }

        if (ocrCandidates.length > 0 || payload.phash != null) {
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

function captureRegion(ctx, canvasEl, canvasX, canvasY, w, h, yBias = 0.5) {
  const sx = Math.max(0, Math.round(canvasX - w / 2))
  const sy = Math.max(0, Math.round(canvasY - h * yBias))
  const sw = Math.min(w, canvasEl.width - sx)
  const sh = Math.min(h, canvasEl.height - sy)
  if (sw <= 0 || sh <= 0) return null
  return { imageData: ctx.getImageData(sx, sy, sw, sh), sx, sy, sw, sh }
}

// Variance of Laplacian — higher = sharper image
function sharpnessScore(imageData) {
  const { data, width, height } = imageData
  const gray = new Float32Array(width * height)
  for (let i = 0; i < width * height; i++) {
    const j = i * 4
    gray[i] = 0.299 * data[j] + 0.587 * data[j + 1] + 0.114 * data[j + 2]
  }
  let sum = 0, sumSq = 0, count = 0
  for (let y = 1; y < height - 1; y++) {
    for (let x = 1; x < width - 1; x++) {
      const idx = y * width + x
      const lap = 4 * gray[idx]
        - gray[idx - 1] - gray[idx + 1]
        - gray[idx - width] - gray[idx + width]
      sum += lap
      sumSq += lap * lap
      count++
    }
  }
  const mean = sum / count
  return (sumSq / count) - mean * mean
}

const MULTI_FRAME_COUNT = 3
const MULTI_FRAME_DELAY_MS = 80

function captureBestFrame(ctx, canvasEl, canvasX, canvasY, w, h, yBias = 0.5) {
  return new Promise((resolve) => {
    const frames = []
    let captured = 0

    const grab = () => {
      const region = captureRegion(ctx, canvasEl, canvasX, canvasY, w, h, yBias)
      if (region) {
        frames.push({ ...region, score: sharpnessScore(region.imageData) })
      }
      captured++
      if (captured < MULTI_FRAME_COUNT) {
        setTimeout(grab, MULTI_FRAME_DELAY_MS)
      } else {
        if (frames.length === 0) { resolve(null); return }
        const best = frames.reduce((a, b) => a.score > b.score ? a : b)
        console.log(`${LOG} Frame sharpness: [${frames.map(f => f.score.toFixed(0)).join(", ")}] → picked ${best.score.toFixed(0)}`)
        resolve(best)
      }
    }
    grab()
  })
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
  const detectW = Math.round(canvasEl.width * DETECT_W_RATIO)
  const detectH = Math.round(canvasEl.height * DETECT_H_RATIO)
  // yBias 0.15: click near top of region (user clicks title, card extends below)
  const detectCapture = captureRegion(ctx, canvasEl, canvasX, canvasY, detectW, detectH, 0.15)

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
      const { card, deskewedImageData, quad, title, art, angle } = detected

      if (container && isDebugEnabled() && quad) {
        fadeBox(showCardQuad(rect, quad, detectCapture, scaleX, scaleY, isFlipped))
      }

      console.log(`${LOG} Card: ${card.width}x${card.height}, angle: ${angle.toFixed(1)}°`)
      console.log(`${LOG} Title: ${title.width}x${title.height} at (${title.x},${title.y})`)
      console.log(`${LOG} Art: ${art.width}x${art.height} at (${art.x},${art.y})`)

      // The worker already deskewed the card — work from the straightened image
      const cardCanvas = imageDataToCanvas(deskewedImageData)
      const cardCtx = cardCanvas.getContext("2d")

      // OCR on title region (already upright from the deskewed card)
      if (title.width > 10 && title.height > 5) {
        const titleImageData = cardCtx.getImageData(title.x, title.y, title.width, title.height)
        result = await processAndOCR(titleImageData)
        console.log(`${LOG} Title OCR: "${result.text}" (${result.confidence})`)
      }

      // Extract art region and compute perceptual hash
      if (art.width > 20 && art.height > 20) {
        const artImageData = cardCtx.getImageData(art.x, art.y, art.width, art.height)
        const artCanvas = imageDataToCanvas(artImageData)
        const artHash = computePHash(artCanvas)
        console.log(`${LOG} Art pHash: ${artHash}`)

        if (result) {
          result.artCanvas = artCanvas
          result.artHash = artHash
        }
      }

      // Detect pitch color from the strip at the top of the card
      const pitchResult = detectPitchColor(deskewedImageData, card.width, card.height)
      if (pitchResult) {
        console.log(`${LOG} Pitch: ${pitchResult.pitch} (confidence: ${(pitchResult.confidence * 100).toFixed(0)}%)`)
      }

      // Attach card-level debug info
      if (!result) {
        result = { text: "", confidence: 0 }
      }
      result.cardCanvas = cardCanvas
      result.angle = angle
      if (pitchResult) {
        result.detectedPitch = pitchResult.pitch
      }
    } else {
      console.log(`${LOG} OpenCV found no card`)
    }
  }

  // --- Step 2: Fallback — small OCR region if OpenCV didn't produce a result ---
  if (!result) {
    console.log(`${LOG} Falling back to fixed-region OCR around click`)
    const fallbackW = Math.round(canvasEl.width * FALLBACK_W_RATIO)
    const fallbackH = Math.round(canvasEl.height * FALLBACK_H_RATIO)
    // Centered on click — assumes user clicked middle of the title text
    const capture = await captureBestFrame(ctx, canvasEl, canvasX, canvasY, fallbackW, fallbackH)

    if (capture) {
      if (container && isDebugEnabled()) {
        fadeBox(showBoundingBox(
          container, rect,
          capture.sx / scaleX, capture.sy / scaleY,
          capture.sw / scaleX, capture.sh / scaleY,
          isFlipped, "oklch(0.75 0.18 145)", "Fallback OCR",
        ))
      }
      result = await processAndOCR(capture.imageData)
      console.log(`${LOG} Fallback OCR: "${result.text}" (${result.confidence})`)
    }
  }

  if (!result) return null

  if (isDebugEnabled()) showDebugPanel(result, result.text, result.confidence)

  return result
}
