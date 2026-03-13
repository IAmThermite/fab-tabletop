// OpenCV Web Worker — detects card-shaped rectangles and title regions

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
// FaB titles sit ~5-9% from top, inset ~18% from edges (past resource icons)
const TITLE_Y_RATIO = 0.055
const TITLE_H_RATIO = 0.04
const TITLE_X_INSET = 0.19

self.onmessage = function (event) {
  const { imageData, requestId } = event.data

  // Always respond so the main thread doesn't hang
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

    // Use adaptive threshold to handle varying lighting
    cv.GaussianBlur(gray, blurred, new cv.Size(5, 5), 0)
    cv.Canny(blurred, edges, 30, 100)

    // Dilate to close gaps in card borders
    kernel = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(3, 3))
    cv.dilate(edges, edges, kernel)
    cv.dilate(edges, edges, kernel) // double dilate for thicker borders

    contours = new cv.MatVector()
    hierarchy = new cv.Mat()

    cv.findContours(
      edges, contours, hierarchy,
      cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE,
    )

    const imgArea = imageData.width * imageData.height
    const centerX = imageData.width / 2
    const centerY = imageData.height / 2
    let bestCard = null
    let bestDist = Infinity
    let bestApproxCount = 0

    for (let i = 0; i < contours.size(); i++) {
      let cnt = contours.get(i)
      let area = cv.contourArea(cnt)

      if (area < imgArea * MIN_CARD_AREA_RATIO) continue
      if (area > imgArea * MAX_CARD_AREA_RATIO) continue

      // Approximate to polygon
      let peri = cv.arcLength(cnt, true)
      let approx = new cv.Mat()
      cv.approxPolyDP(cnt, approx, 0.02 * peri, true)

      let rect = cv.boundingRect(cnt)

      // Filter by portrait card aspect ratio
      let aspect = rect.height / rect.width
      if (aspect < MIN_ASPECT || aspect > MAX_ASPECT) {
        approx.delete()
        continue
      }

      // Accept any roughly rectangular contour (4-12 vertices)
      // Pick the one whose center is closest to the click point (center of region)
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

    if (bestCard) {
      let cardX = bestCard.x
      let cardY = bestCard.y
      let cardW = bestCard.width
      let cardH = bestCard.height

      // Title is always at the top of the detected bounding rect
      let titleX = cardX + Math.round(cardW * TITLE_X_INSET)
      let titleY = cardY + Math.round(cardH * TITLE_Y_RATIO)
      let titleW = Math.round(cardW * (1 - 2 * TITLE_X_INSET))
      let titleH = Math.round(cardH * TITLE_H_RATIO)

      // Clamp to image bounds
      titleX = Math.max(0, Math.min(titleX, imageData.width - 1))
      titleY = Math.max(0, Math.min(titleY, imageData.height - 1))
      titleW = Math.min(titleW, imageData.width - titleX)
      titleH = Math.min(titleH, imageData.height - titleY)

      const cardArea = cardW * cardH
      console.log(`${LOG} Card: ${cardW}x${cardH} at (${cardX},${cardY}), vertices: ${bestApproxCount}, area: ${(cardArea / imgArea * 100).toFixed(1)}%, dist: ${bestDist.toFixed(0)}`)
      console.log(`${LOG} Title: ${titleW}x${titleH} at (${titleX},${titleY})`)

      self.postMessage({
        type: "cardDetected",
        requestId,
        card: { x: cardX, y: cardY, width: cardW, height: cardH },
        title: { x: titleX, y: titleY, width: titleW, height: titleH },
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
