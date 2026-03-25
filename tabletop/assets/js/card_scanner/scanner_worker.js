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

// Portrait card aspect ratio: long/short ~1.2 to 2.0 (standard FaB is ~1.4)
const MIN_ASPECT = 1.1
const MAX_ASPECT = 2.0

// Title region: narrow banner near top of card
const TITLE_Y_RATIO = 0.055
const TITLE_H_RATIO = 0.04
const TITLE_X_INSET = 0.19

// Art region: main illustration area
const ART_Y_RATIO = 0.16
const ART_H_RATIO = 0.42
const ART_X_INSET = 0.10

/**
 * Use approxPolyDP to find the best 4-point polygon approximation of a contour.
 * Returns null if no good quad is found, or an array of 4 {x,y} points.
 */
function findQuad(cv, contour) {
  const peri = cv.arcLength(contour, true)

  // Try a range of epsilon values to find a good 4-sided polygon
  for (let eps = 0.02; eps <= 0.10; eps += 0.01) {
    const approx = new cv.Mat()
    cv.approxPolyDP(contour, approx, eps * peri, true)

    if (approx.rows === 4) {
      const pts = []
      for (let i = 0; i < 4; i++) {
        pts.push({ x: approx.data32S[i * 2], y: approx.data32S[i * 2 + 1] })
      }
      approx.delete()
      return pts
    }
    approx.delete()
  }
  return null
}

/**
 * Order 4 corner points as [top-left, top-right, bottom-right, bottom-left].
 * Uses sum (x+y) and difference (x-y) method which is robust to any rotation.
 */
function orderCorners(pts) {
  const sums = pts.map(p => p.x + p.y)
  const diffs = pts.map(p => p.x - p.y)

  // Top-left has smallest sum, bottom-right has largest sum
  const tl = pts[sums.indexOf(Math.min(...sums))]
  const br = pts[sums.indexOf(Math.max(...sums))]
  // Top-right has largest diff, bottom-left has smallest diff
  const tr = pts[diffs.indexOf(Math.max(...diffs))]
  const bl = pts[diffs.indexOf(Math.min(...diffs))]

  return [tl, tr, br, bl]
}

function dist(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y)
}

function findBestContour(cv, contours, imgArea, centerX, centerY) {
  let bestQuad = null
  let bestDist = Infinity
  let bestArea = 0

  for (let i = 0; i < contours.size(); i++) {
    const cnt = contours.get(i)
    const area = cv.contourArea(cnt)

    if (area < imgArea * MIN_CARD_AREA_RATIO) continue
    if (area > imgArea * MAX_CARD_AREA_RATIO) continue

    const quad = findQuad(cv, cnt)
    if (!quad) continue

    // Check aspect ratio using the actual corner distances
    const ordered = orderCorners(quad)
    const widthTop = dist(ordered[0], ordered[1])
    const widthBot = dist(ordered[3], ordered[2])
    const heightLeft = dist(ordered[0], ordered[3])
    const heightRight = dist(ordered[1], ordered[2])

    const avgW = (widthTop + widthBot) / 2
    const avgH = (heightLeft + heightRight) / 2
    const longSide = Math.max(avgW, avgH)
    const shortSide = Math.min(avgW, avgH)

    if (shortSide < 1) continue
    const aspect = longSide / shortSide
    if (aspect < MIN_ASPECT || aspect > MAX_ASPECT) continue

    // Prefer contour closest to center of the image
    const cx = quad.reduce((s, p) => s + p.x, 0) / 4
    const cy = quad.reduce((s, p) => s + p.y, 0) / 4
    const d = Math.hypot(cx - centerX, cy - centerY)

    if (d < bestDist) {
      bestDist = d
      bestQuad = ordered
      bestArea = area
    }
  }

  return { bestQuad, bestDist, bestArea }
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

    const imgArea = imageData.width * imageData.height
    const centerX = imageData.width / 2
    const centerY = imageData.height / 2

    // Try multiple edge detection strategies to handle different lighting
    const strategies = [
      { blur: 5, cannyLow: 30, cannyHigh: 100, dilations: 2 },
      { blur: 5, cannyLow: 15, cannyHigh: 60,  dilations: 2 },
      { blur: 3, cannyLow: 50, cannyHigh: 150, dilations: 1 },
      { blur: 7, cannyLow: 20, cannyHigh: 80,  dilations: 3 },
    ]

    let bestQuad = null
    let bestDist = Infinity

    for (const strat of strategies) {
      cv.GaussianBlur(gray, blurred, new cv.Size(strat.blur, strat.blur), 0)
      cv.Canny(blurred, edges, strat.cannyLow, strat.cannyHigh)

      kernel = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(3, 3))
      for (let d = 0; d < strat.dilations; d++) {
        cv.dilate(edges, edges, kernel)
      }
      kernel.delete()
      kernel = null

      contours = new cv.MatVector()
      hierarchy = new cv.Mat()

      cv.findContours(
        edges, contours, hierarchy,
        cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE,
      )

      const result = findBestContour(cv, contours, imgArea, centerX, centerY)

      contours.delete()
      hierarchy.delete()
      contours = null
      hierarchy = null

      if (result.bestQuad && result.bestDist < bestDist) {
        bestQuad = result.bestQuad
        bestDist = result.bestDist
      }

      // Good enough — stop early
      if (bestQuad && bestDist < Math.min(imageData.width, imageData.height) * 0.15) break
    }

    if (bestQuad) {
      // bestQuad is ordered [TL, TR, BR, BL]
      // Determine orientation: is the card portrait or landscape?
      const widthTop = dist(bestQuad[0], bestQuad[1])
      const heightLeft = dist(bestQuad[0], bestQuad[3])

      let cardW, cardH, srcCorners
      if (heightLeft >= widthTop) {
        // Already portrait: top edge is the short side
        cardW = Math.round(widthTop)
        cardH = Math.round(heightLeft)
        srcCorners = bestQuad // TL, TR, BR, BL maps to upright
      } else {
        // Landscape: the "top" of the card is actually the left edge
        // Rotate the mapping: BL→TL, TL→TR, TR→BR, BR→BL
        cardW = Math.round(heightLeft)
        cardH = Math.round(widthTop)
        srcCorners = [bestQuad[3], bestQuad[0], bestQuad[1], bestQuad[2]]
      }

      // Compute approximate angle for logging
      const dx = bestQuad[1].x - bestQuad[0].x
      const dy = bestQuad[1].y - bestQuad[0].y
      const angle = Math.atan2(dy, dx) * (180 / Math.PI)

      // Source points (the detected corners in the original image)
      let srcPts = cv.matFromArray(4, 1, cv.CV_32FC2, [
        srcCorners[0].x, srcCorners[0].y,
        srcCorners[1].x, srcCorners[1].y,
        srcCorners[2].x, srcCorners[2].y,
        srcCorners[3].x, srcCorners[3].y,
      ])

      // Destination points (upright rectangle)
      let dstPts = cv.matFromArray(4, 1, cv.CV_32FC2, [
        0, 0,
        cardW, 0,
        cardW, cardH,
        0, cardH,
      ])

      // Perspective warp to deskew the card
      let M = cv.getPerspectiveTransform(srcPts, dstPts)
      let warped = new cv.Mat()
      cv.warpPerspective(src, warped, M, new cv.Size(cardW, cardH))

      // Extract the deskewed card as RGBA ImageData
      let warpedRGBA = new cv.Mat()
      if (warped.channels() === 4) {
        warpedRGBA = warped
      } else if (warped.channels() === 3) {
        cv.cvtColor(warped, warpedRGBA, cv.COLOR_RGB2RGBA)
      } else {
        cv.cvtColor(warped, warpedRGBA, cv.COLOR_GRAY2RGBA)
      }

      const cardData = new Uint8ClampedArray(warpedRGBA.data)

      // Extract title and art regions from the deskewed card
      const title = {
        x: Math.round(cardW * TITLE_X_INSET),
        y: Math.round(cardH * TITLE_Y_RATIO),
        width: Math.round(cardW * (1 - 2 * TITLE_X_INSET)),
        height: Math.round(cardH * TITLE_H_RATIO),
      }

      const art = {
        x: Math.round(cardW * ART_X_INSET),
        y: Math.round(cardH * ART_Y_RATIO),
        width: Math.round(cardW * (1 - 2 * ART_X_INSET)),
        height: Math.round(cardH * ART_H_RATIO),
      }

      const cardArea = cardW * cardH
      console.log(`${LOG} Card: ${cardW}x${cardH}, angle: ${angle.toFixed(1)}°, area: ${(cardArea / imgArea * 100).toFixed(1)}%, dist: ${bestDist.toFixed(0)}`)
      console.log(`${LOG} Title: ${title.width}x${title.height} at (${title.x},${title.y})`)
      console.log(`${LOG} Art: ${art.width}x${art.height} at (${art.x},${art.y})`)

      self.postMessage({
        type: "cardDetected",
        requestId,
        card: { width: cardW, height: cardH },
        cardImageData: cardData.buffer,
        quad: bestQuad,
        title,
        art,
        angle,
      }, [cardData.buffer])

      srcPts.delete()
      dstPts.delete()
      M.delete()
      if (warpedRGBA !== warped) warpedRGBA.delete()
      warped.delete()
    } else {
      console.log(`${LOG} No card found after ${strategies.length} strategies`)
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
