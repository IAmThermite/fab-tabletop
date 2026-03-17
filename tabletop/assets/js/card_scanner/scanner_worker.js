// OpenCV Web Worker — detects card-shaped rectangles, title, and art regions

const LOG = "[ScannerWorker]"

console.log(`${LOG} Worker starting, about to importScripts OpenCV...`)

try {
  importScripts("https://cdn.jsdelivr.net/npm/@techstark/opencv-js@4.12.0-release.1/dist/opencv.js")
  console.log(`${LOG} importScripts completed`)
} catch (e) {
  console.error(`${LOG} importScripts FAILED:`, e.message)
  self.postMessage({ type: "error", message: `importScripts failed: ${e.message}` })
}

let cvReady = false
let cvModule = null

function onReady(module) {
  cvModule = module
  cvReady = true
  console.log(`${LOG} OpenCV fully initialized!`)
  self.postMessage({ type: "ready" })
}

;(function initOpenCV() {
  if (typeof cv === "undefined") {
    self.postMessage({ type: "error", message: "cv is undefined after importScripts" })
    return
  }
  if (typeof cv.Mat === "function") { onReady(cv); return }
  if (typeof cv.then === "function") {
    cv.then(function (module) { onReady(module) })
    return
  }
  if (typeof cv === "function") {
    const result = cv()
    if (result && typeof result.then === "function") {
      result.then(function (module) { onReady(module) })
    }
    return
  }
  const poll = setInterval(() => {
    if (typeof cv.Mat === "function") { clearInterval(poll); onReady(cv) }
  }, 100)
  setTimeout(() => { clearInterval(poll); if (!cvReady) self.postMessage({ type: "error", message: "OpenCV init timed out" }) }, 30000)
})()

// Card must be at least 2% but no more than 60% of image area
const MIN_CARD_AREA_RATIO = 0.02
const MAX_CARD_AREA_RATIO = 0.60

// Portrait card aspect ratio: height/width ~1.2 to 1.8 (standard is ~1.4)
const MIN_ASPECT = 1.1
const MAX_ASPECT = 2.0

// Title region: narrow banner near top of card
const TITLE_Y_RATIO = 0.055
const TITLE_H_RATIO = 0.04
const TITLE_X_INSET = 0.19

// Art region: main illustration area
const ART_Y_RATIO = 0.11
const ART_H_RATIO = 0.505
const ART_X_INSET = 0.06

function clampRect(rect, imgW, imgH) {
  let { x, y, width, height } = rect
  x = Math.max(0, Math.min(x, imgW - 1))
  y = Math.max(0, Math.min(y, imgH - 1))
  width = Math.min(width, imgW - x)
  height = Math.min(height, imgH - y)
  return { x, y, width, height }
}

function extractRegions(cardX, cardY, cardW, cardH, imgW, imgH) {
  const title = clampRect({
    x: cardX + Math.round(cardW * TITLE_X_INSET),
    y: cardY + Math.round(cardH * TITLE_Y_RATIO),
    width: Math.round(cardW * (1 - 2 * TITLE_X_INSET)),
    height: Math.round(cardH * TITLE_H_RATIO),
  }, imgW, imgH)

  const art = clampRect({
    x: cardX + Math.round(cardW * ART_X_INSET),
    y: cardY + Math.round(cardH * ART_Y_RATIO),
    width: Math.round(cardW * (1 - 2 * ART_X_INSET)),
    height: Math.round(cardH * ART_H_RATIO),
  }, imgW, imgH)

  return { title, art }
}

function findBestContour(contours, imgArea, centerX, centerY, minAspect, maxAspect) {
  let bestCard = null
  let bestDist = Infinity
  let bestApproxCount = 0

  for (let i = 0; i < contours.size(); i++) {
    let cnt = contours.get(i)
    let area = cv.contourArea(cnt)

    if (area < imgArea * MIN_CARD_AREA_RATIO) continue
    if (area > imgArea * MAX_CARD_AREA_RATIO) continue

    let peri = cv.arcLength(cnt, true)
    let approx = new cv.Mat()
    cv.approxPolyDP(cnt, approx, 0.02 * peri, true)

    let rect = cv.boundingRect(cnt)

    let aspect = rect.height / rect.width
    if (aspect < minAspect || aspect > maxAspect) {
      approx.delete()
      continue
    }

    if (approx.rows >= 4 && approx.rows <= 12) {
      const cx = rect.x + rect.width / 2
      const cy = rect.y + rect.height / 2
      const dist = Math.hypot(cx - centerX, cy - centerY)
      if (dist < bestDist) {
        bestDist = dist
        bestCard = rect
        bestApproxCount = approx.rows
      }
    }

    approx.delete()
  }

  return { bestCard, bestDist, bestApproxCount }
}

self.onmessage = function (event) {
  const { imageData, requestId } = event.data

  if (!cvReady || !cvModule) {
    self.postMessage({ type: "noCard", requestId, reason: "not ready" })
    return
  }

  const cv = cvModule
  let src, gray, blurred, edges, kernel, contours, hierarchy

  try {
    src = cv.matFromImageData(imageData)
    gray = new cv.Mat()
    blurred = new cv.Mat()
    edges = new cv.Mat()

    cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY)
    cv.GaussianBlur(gray, blurred, new cv.Size(5, 5), 0)
    cv.Canny(blurred, edges, 30, 100)

    kernel = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(3, 3))
    cv.dilate(edges, edges, kernel)
    cv.dilate(edges, edges, kernel)

    contours = new cv.MatVector()
    hierarchy = new cv.Mat()

    cv.findContours(
      edges, contours, hierarchy,
      cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE,
    )

    const imgArea = imageData.width * imageData.height
    const centerX = imageData.width / 2
    const centerY = imageData.height / 2

    // Pass 1: Look for portrait-oriented cards
    let { bestCard, bestDist, bestApproxCount } = findBestContour(
      contours, imgArea, centerX, centerY, MIN_ASPECT, MAX_ASPECT
    )
    let rotation = 0

    // Pass 2: If no portrait card found, look for landscape (90-degree rotated)
    if (!bestCard) {
      const landscape = findBestContour(
        contours, imgArea, centerX, centerY, 1 / MAX_ASPECT, 1 / MIN_ASPECT
      )
      if (landscape.bestCard) {
        bestCard = landscape.bestCard
        bestDist = landscape.bestDist
        bestApproxCount = landscape.bestApproxCount
        rotation = 90
        console.log(`${LOG} Detected landscape card (90° rotation)`)
      }
    }

    if (bestCard) {
      let cardX = bestCard.x
      let cardY = bestCard.y
      let cardW = bestCard.width
      let cardH = bestCard.height

      let title, art
      if (rotation === 90) {
        // Card is landscape — title is along the left or right short edge
        // We'll report the raw landscape rect and let the main thread handle rotation
        // Compute regions as if rotated to portrait (swap W/H for ratio calculations)
        const portraitW = cardH
        const portraitH = cardW

        // Title along the top of the "virtual portrait" = left edge of landscape
        title = clampRect({
          x: cardX,
          y: cardY + Math.round(portraitW * TITLE_X_INSET),
          width: Math.round(portraitH * TITLE_H_RATIO),
          height: Math.round(portraitW * (1 - 2 * TITLE_X_INSET)),
        }, imageData.width, imageData.height)

        art = clampRect({
          x: cardX + Math.round(portraitH * ART_Y_RATIO),
          y: cardY + Math.round(portraitW * ART_X_INSET),
          width: Math.round(portraitH * ART_H_RATIO),
          height: Math.round(portraitW * (1 - 2 * ART_X_INSET)),
        }, imageData.width, imageData.height)
      } else {
        const regions = extractRegions(cardX, cardY, cardW, cardH, imageData.width, imageData.height)
        title = regions.title
        art = regions.art
      }

      const cardArea = cardW * cardH
      console.log(`${LOG} Card: ${cardW}x${cardH} at (${cardX},${cardY}), vertices: ${bestApproxCount}, area: ${(cardArea / imgArea * 100).toFixed(1)}%, dist: ${bestDist.toFixed(0)}, rotation: ${rotation}`)
      console.log(`${LOG} Title: ${title.width}x${title.height} at (${title.x},${title.y})`)
      console.log(`${LOG} Art: ${art.width}x${art.height} at (${art.x},${art.y})`)

      self.postMessage({
        type: "cardDetected",
        requestId,
        card: { x: cardX, y: cardY, width: cardW, height: cardH },
        title,
        art,
        rotation,
      })
    } else {
      console.log(`${LOG} No card found (${contours.size()} contours checked)`)
      self.postMessage({ type: "noCard", requestId })
    }
  } catch (err) {
    console.error(`${LOG} Processing error:`, err.message)
    self.postMessage({ type: "noCard", requestId, reason: err.message })
  } finally {
    if (src) src.delete()
    if (gray) gray.delete()
    if (blurred) blurred.delete()
    if (edges) edges.delete()
    if (kernel) kernel.delete()
    if (contours) contours.delete()
    if (hierarchy) hierarchy.delete()
  }
}
