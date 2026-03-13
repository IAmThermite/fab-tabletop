// Card Scanner — click-to-capture OCR for identifying cards in video feed
//
// Pipeline:
// 1. Capture fixed region around click, preprocess, run OCR
// 2. If confidence < 65%, send full canvas to OpenCV to detect the whole card,
//    extract the title region, and retry OCR on that

import { preprocessForOCR, cropMargins } from "./preprocessing"
import { preloadOCR, runOCR } from "./ocr"
import { showDebugPanel, showBoundingBox } from "./debug"

const LOG = "[CardScanner]"
const CONFIDENCE_THRESHOLD = 65
const BOX_LINGER_MS = 3000

// Capture regions as fraction of canvas size
// OCR region: narrow strip for title text
const CAPTURE_W_RATIO = 0.15
const CAPTURE_H_RATIO = 0.04

// Detect region: enough to contain one portrait card with margin
const DETECT_W_RATIO = 0.25
const DETECT_H_RATIO = 0.50

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
      // Ignore messages from other requests
      if (event.data.requestId !== requestId) return

      clearTimeout(timeout)
      worker.removeEventListener("message", handler)

      if (event.data.type === "cardDetected") {
        resolve({ card: event.data.card, title: event.data.title })
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
  // yBias: 0.5 = centered, 0.15 = click near top of region (region extends mostly down)
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
      // Laplacian kernel: [0,-1,0; -1,4,-1; 0,-1,0]
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

// Capture multiple frames and return the sharpest one
function captureBestFrame(ctx, canvasEl, canvasX, canvasY, w, h) {
  return new Promise((resolve) => {
    const frames = []
    let captured = 0

    const grab = () => {
      const region = captureRegion(ctx, canvasEl, canvasX, canvasY, w, h)
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
  const { processedCanvas, rawCanvas, grayCanvas, upGrayCanvas } = preprocessForOCR(imageData)

  // Run OCR on all three preprocessed images in parallel
  const [grayResult, upGrayResult, threshResult] = await Promise.all([
    runOCR(cropMargins(grayCanvas)),
    runOCR(cropMargins(upGrayCanvas)),
    runOCR(cropMargins(processedCanvas)),
  ])

  console.log(`${LOG} Grayscale OCR: "${grayResult.text}" (${grayResult.confidence})`)
  console.log(`${LOG} Upscaled gray OCR: "${upGrayResult.text}" (${upGrayResult.confidence})`)
  console.log(`${LOG} Threshold OCR: "${threshResult.text}" (${threshResult.confidence})`)

  // Pick the best result
  const candidates = [
    { label: "gray", result: grayResult },
    { label: "upGray", result: upGrayResult },
    { label: "thresh", result: threshResult },
  ]
  const best = candidates.reduce((a, b) => a.result.confidence > b.result.confidence ? a : b)
  console.log(`${LOG} Best: ${best.label} (${best.result.confidence})`)

  return {
    ...best.result,
    rawCanvas, grayCanvas, upGrayCanvas, processedCanvas,
    grayConfidence: grayResult.confidence,
    grayText: grayResult.text,
    upGrayConfidence: upGrayResult.confidence,
    upGrayText: upGrayResult.text,
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

  // --- Pass 1: multi-frame capture, pick sharpest, then OCR ---
  const captureW = Math.round(canvasEl.width * CAPTURE_W_RATIO)
  const captureH = Math.round(canvasEl.height * CAPTURE_H_RATIO)
  const capture = await captureBestFrame(ctx, canvasEl, canvasX, canvasY, captureW, captureH)
  if (!capture) return ""

  const boxes = []
  if (container) {
    boxes.push(showBoundingBox(
      container, rect,
      capture.sx / scaleX, capture.sy / scaleY,
      capture.sw / scaleX, capture.sh / scaleY,
      isFlipped, "oklch(0.75 0.18 145)", "OCR",
    ))
  }

  let result = await processAndOCR(capture.imageData)
  console.log(`${LOG} Pass 1: "${result.text}" (confidence: ${result.confidence})`)

  // --- Pass 2: OpenCV on full canvas if confidence is low ---
  if (result.confidence < CONFIDENCE_THRESHOLD) {
    console.log(`${LOG} Low confidence (${result.confidence} < ${CONFIDENCE_THRESHOLD}), running OpenCV on region around click...`)

    // Capture a larger region around the click for OpenCV card detection
    const detectW = Math.round(canvasEl.width * DETECT_W_RATIO)
    const detectH = Math.round(canvasEl.height * DETECT_H_RATIO)
    // yBias 0.15: click point sits near top of region (user clicks on title, card extends below)
    const detectCapture = captureRegion(ctx, canvasEl, canvasX, canvasY, detectW, detectH, 0.15)

    if (!detectCapture) {
      console.log(`${LOG} Could not capture detection region`)
    } else {
      if (container) {
        const detectBox = showBoundingBox(
          container, rect,
          detectCapture.sx / scaleX, detectCapture.sy / scaleY,
          detectCapture.sw / scaleX, detectCapture.sh / scaleY,
          isFlipped, "oklch(0.65 0.12 280)", "Detect",
        )
        fadeBox(detectBox)
      }

      const detected = await detectCard(detectCapture.imageData)

      if (detected) {
        // Offset detected coordinates from region-local to full-canvas coordinates
        const { card, title } = detected
        const absCard = {
          x: card.x + detectCapture.sx, y: card.y + detectCapture.sy,
          width: card.width, height: card.height,
        }
        const absTitle = {
          x: title.x + detectCapture.sx, y: title.y + detectCapture.sy,
          width: title.width, height: title.height,
        }

        console.log(`${LOG} Card: ${absCard.width}x${absCard.height} at (${absCard.x},${absCard.y})`)
        console.log(`${LOG} Title: ${absTitle.width}x${absTitle.height} at (${absTitle.x},${absTitle.y})`)

        // Show card bounding box (blue)
        if (container) {
          const cardBox = showBoundingBox(
            container, rect,
            absCard.x / scaleX, absCard.y / scaleY,
            absCard.width / scaleX, absCard.height / scaleY,
            isFlipped, "oklch(0.70 0.15 250)", "Card",
          )
          fadeBox(cardBox)
        }

        // Show title bounding box (orange) and run OCR on it
        if (absTitle.width > 20 && absTitle.height > 10) {
          if (container) {
            const titleBox = showBoundingBox(
              container, rect,
              absTitle.x / scaleX, absTitle.y / scaleY,
              absTitle.width / scaleX, absTitle.height / scaleY,
              isFlipped, "oklch(0.75 0.18 55)", "Title",
            )
            fadeBox(titleBox)
          }

          const titleImageData = ctx.getImageData(absTitle.x, absTitle.y, absTitle.width, absTitle.height)
          const pass2 = await processAndOCR(titleImageData)
          console.log(`${LOG} Pass 2: "${pass2.text}" (confidence: ${pass2.confidence})`)

          if (pass2.confidence > result.confidence) {
            result = pass2
          }
        }
      } else {
        console.log(`${LOG} OpenCV found no card`)
      }
    }
  } else {
    console.log(`${LOG} Confidence above threshold, skipping OpenCV`)
  }

  // Fade out pass 1 boxes
  for (const box of boxes) {
    fadeBox(box)
  }

  showDebugPanel(result, result.text, result.confidence)

  return result.text
}
