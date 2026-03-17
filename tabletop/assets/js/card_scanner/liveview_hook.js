// Card Scanner — click-to-capture OCR for identifying cards in video feed
//
// Pipeline:
// 1. Run OpenCV to detect the card, extract title for OCR and art for pHash
// 2. If OpenCV fails, fall back to a small fixed-region OCR around the click

import { preprocessForOCR, cropMargins, rotateCanvas90, imageDataToCanvas } from "./preprocessing"
import { preloadOCR, runOCR } from "./ocr"
import { showDebugPanel, showBoundingBox } from "./debug"
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
        resolve({
          card: event.data.card,
          title: event.data.title,
          art: event.data.art,
          rotation: event.data.rotation || 0,
        })
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
    if (container) {
      fadeBox(showBoundingBox(
        container, rect,
        detectCapture.sx / scaleX, detectCapture.sy / scaleY,
        detectCapture.sw / scaleX, detectCapture.sh / scaleY,
        isFlipped, "oklch(0.65 0.12 280)", "Detect",
      ))
    }

    const detected = await detectCard(detectCapture.imageData)

    if (detected) {
      const { card, title, art, rotation } = detected
      const ox = detectCapture.sx
      const oy = detectCapture.sy

      const absCard = { x: card.x + ox, y: card.y + oy, width: card.width, height: card.height }
      const absTitle = { x: title.x + ox, y: title.y + oy, width: title.width, height: title.height }
      const absArt = { x: art.x + ox, y: art.y + oy, width: art.width, height: art.height }

      console.log(`${LOG} Card: ${absCard.width}x${absCard.height} at (${absCard.x},${absCard.y}), rotation: ${rotation}`)
      console.log(`${LOG} Title: ${absTitle.width}x${absTitle.height}`)
      console.log(`${LOG} Art: ${absArt.width}x${absArt.height}`)

      // Show card bounding box (blue)
      if (container) {
        fadeBox(showBoundingBox(
          container, rect,
          absCard.x / scaleX, absCard.y / scaleY,
          absCard.width / scaleX, absCard.height / scaleY,
          isFlipped, "oklch(0.70 0.15 250)", rotation ? `Card ↻${rotation}°` : "Card",
        ))
      }

      // Capture full card region for debug
      let cardCanvas = imageDataToCanvas(ctx.getImageData(absCard.x, absCard.y, absCard.width, absCard.height))
      if (rotation === 90) {
        cardCanvas = rotateCanvas90(cardCanvas, "cw")
      }

      // OCR on detected title region
      if (absTitle.width > 10 && absTitle.height > 5) {
        if (container) {
          fadeBox(showBoundingBox(
            container, rect,
            absTitle.x / scaleX, absTitle.y / scaleY,
            absTitle.width / scaleX, absTitle.height / scaleY,
            isFlipped, "oklch(0.75 0.18 55)", "Title",
          ))
        }

        let titleImageData = ctx.getImageData(absTitle.x, absTitle.y, absTitle.width, absTitle.height)

        if (rotation === 90) {
          const titleCanvas = imageDataToCanvas(titleImageData)
          const cwCanvas = rotateCanvas90(titleCanvas, "cw")
          const ccwCanvas = rotateCanvas90(titleCanvas, "ccw")
          const [cwResult, ccwResult] = await Promise.all([
            processAndOCR(cwCanvas.getContext("2d").getImageData(0, 0, cwCanvas.width, cwCanvas.height)),
            processAndOCR(ccwCanvas.getContext("2d").getImageData(0, 0, ccwCanvas.width, ccwCanvas.height)),
          ])
          console.log(`${LOG} Title OCR (CW): "${cwResult.text}" (${cwResult.confidence})`)
          console.log(`${LOG} Title OCR (CCW): "${ccwResult.text}" (${ccwResult.confidence})`)
          result = cwResult.confidence >= ccwResult.confidence ? { ...cwResult, rotation } : { ...ccwResult, rotation }
        } else {
          result = await processAndOCR(titleImageData)
          console.log(`${LOG} Title OCR: "${result.text}" (${result.confidence})`)
        }
      }

      // Extract art region and compute perceptual hash
      if (absArt.width > 20 && absArt.height > 20) {
        if (container) {
          fadeBox(showBoundingBox(
            container, rect,
            absArt.x / scaleX, absArt.y / scaleY,
            absArt.width / scaleX, absArt.height / scaleY,
            isFlipped, "oklch(0.70 0.15 195)", "Art",
          ))
        }

        const artImageData = ctx.getImageData(absArt.x, absArt.y, absArt.width, absArt.height)
        let artCanvas = imageDataToCanvas(artImageData)

        if (rotation === 90) {
          artCanvas = rotateCanvas90(artCanvas, "cw")
        }

        const artHash = computePHash(artCanvas)
        console.log(`${LOG} Art pHash: ${artHash}`)

        if (result) {
          result.artCanvas = artCanvas
          result.artHash = artHash
        }
      }

      // Attach card-level debug info to result (create stub if OCR didn't produce one)
      if (!result) {
        result = { text: "", confidence: 0 }
      }
      result.cardCanvas = cardCanvas
      result.rotation = rotation
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
      if (container) {
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

  if (!result) return ""

  showDebugPanel(result, result.text, result.confidence)

  return result.text
}
