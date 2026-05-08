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

// Card must be at least 5% but no more than 60% of image area
const MIN_CARD_AREA_RATIO = 0.05
const MAX_CARD_AREA_RATIO = 0.60

// Portrait card aspect ratio: long/short ~1.2 to 2.0 (standard FaB is ~1.4)
const MIN_ASPECT = 1.1
const MAX_ASPECT = 2.0

// Rectangularity: reject trapezoids from card art features
const MIN_SIDE_RATIO = 0.75       // opposite sides must be within 75% of each other
const MAX_CORNER_DEVIATION = 25   // max degrees any corner can deviate from 90°

// Title region: narrow banner near top of card
const TITLE_Y_RATIO = 0.1
const TITLE_H_RATIO = 0.04
const TITLE_X_INSET = 0.19

// Art region: main illustration area
const ART_Y_RATIO = 0.16
const ART_H_RATIO = 0.42
const ART_X_INSET = 0.10

/**
 * Detect whether the deskewed card is upside-down by comparing color saturation
 * of the top strip vs bottom strip. FaB cards have a colored pitch band at top.
 *
 * Returns "upright", "flipped", or "uncertain".
 */
function detectOrientation(cardData, cardW, cardH) {
  const topY0 = Math.round(cardH * 0.01)
  const topY1 = Math.round(cardH * 0.04)
  const botY0 = Math.round(cardH * 0.96)
  const botY1 = Math.round(cardH * 0.99)
  const x0 = Math.round(cardW * 0.25)
  const x1 = Math.round(cardW * 0.75)

  let topSaturated = 0, topTotal = 0
  let botSaturated = 0, botTotal = 0

  for (let y = topY0; y < topY1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * cardW + x) * 4
      const r = cardData[i], g = cardData[i + 1], b = cardData[i + 2]
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const v = max / 255
      const s = max === 0 ? 0 : (max - min) / max
      topTotal++
      if (s > 0.20 && v > 0.15) topSaturated++
    }
  }

  for (let y = botY0; y < botY1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * cardW + x) * 4
      const r = cardData[i], g = cardData[i + 1], b = cardData[i + 2]
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const v = max / 255
      const s = max === 0 ? 0 : (max - min) / max
      botTotal++
      if (s > 0.20 && v > 0.15) botSaturated++
    }
  }

  const topRatio = topTotal > 0 ? topSaturated / topTotal : 0
  const botRatio = botTotal > 0 ? botSaturated / botTotal : 0

  console.log(`${LOG} Orientation check — top saturation: ${(topRatio * 100).toFixed(0)}%, bottom: ${(botRatio * 100).toFixed(0)}%`)

  // If one strip has clearly more color than the other, we can determine orientation
  if (botRatio > topRatio * 1.5 && botRatio > 0.15) return "flipped"
  if (topRatio > botRatio * 1.5 && topRatio > 0.15) return "upright"
  return "uncertain"
}

/**
 * Rotate an RGBA pixel buffer 180 degrees in-place.
 */
function rotateBuffer180(data, width, height) {
  const totalPixels = width * height
  const half = Math.floor(totalPixels / 2)

  for (let i = 0; i < half; i++) {
    const j = totalPixels - 1 - i
    const ai = i * 4, bi = j * 4
    // Swap RGBA values
    const r = data[ai], g = data[ai + 1], b = data[ai + 2], a = data[ai + 3]
    data[ai] = data[bi]; data[ai + 1] = data[bi + 1]; data[ai + 2] = data[bi + 2]; data[ai + 3] = data[bi + 3]
    data[bi] = r; data[bi + 1] = g; data[bi + 2] = b; data[bi + 3] = a
  }
}

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

/**
 * Compute angle (in degrees) at point b, formed by edges ba and bc.
 */
function cornerAngle(a, b, c) {
  const ba = { x: a.x - b.x, y: a.y - b.y }
  const bc = { x: c.x - b.x, y: c.y - b.y }
  const dot = ba.x * bc.x + ba.y * bc.y
  const magBA = Math.hypot(ba.x, ba.y)
  const magBC = Math.hypot(bc.x, bc.y)
  if (magBA < 1 || magBC < 1) return 0
  return Math.acos(Math.max(-1, Math.min(1, dot / (magBA * magBC)))) * (180 / Math.PI)
}

/**
 * Check that a quad is convex by verifying all cross products have the same sign.
 */
function isConvexQuad(pts) {
  let sign = 0
  for (let i = 0; i < 4; i++) {
    const a = pts[i]
    const b = pts[(i + 1) % 4]
    const c = pts[(i + 2) % 4]
    const cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
    if (cross === 0) continue
    if (sign === 0) sign = Math.sign(cross)
    else if (Math.sign(cross) !== sign) return false
  }
  return true
}

// Canonical FaB card aspect (long/short). Used as a soft preference in scoring
// so that two-card merge blobs (aspect drifts toward 1.0 or beyond ~2× target)
// lose to individual card contours that sit inside them.
const TARGET_ASPECT = 1.4

function quadAABB(pts) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (const p of pts) {
    if (p.x < minX) minX = p.x
    if (p.y < minY) minY = p.y
    if (p.x > maxX) maxX = p.x
    if (p.y > maxY) maxY = p.y
  }
  const area = Math.max(0, (maxX - minX) * (maxY - minY))
  return { minX, minY, maxX, maxY, area }
}

function aabbIntersectionArea(a, b) {
  const w = Math.max(0, Math.min(a.maxX, b.maxX) - Math.max(a.minX, b.minX))
  const h = Math.max(0, Math.min(a.maxY, b.maxY) - Math.max(a.minY, b.minY))
  return w * h
}

/**
 * Greedy suppression over candidate quads:
 *   - High IoU pair (>0.6): keep the higher-scored one (standard NMS — same
 *     physical card detected via inner+outer edge contours).
 *   - High containment (>0.8) with the smaller quad at 30-70% of the larger:
 *     prefer the SMALLER one. This catches a merged two-card blob enclosing
 *     a single-card contour and picks the individual card.
 */
function suppressCandidates(candidates) {
  const sorted = [...candidates].sort((a, b) => b.score - a.score)
  const survivors = []
  for (const cand of sorted) {
    let drop = false
    let replaceIndex = -1
    for (let i = 0; i < survivors.length; i++) {
      const s = survivors[i]
      const inter = aabbIntersectionArea(cand.aabb, s.aabb)
      if (inter === 0) continue
      const union = cand.aabb.area + s.aabb.area - inter
      const iou = union > 0 ? inter / union : 0
      const smallerArea = Math.min(cand.aabb.area, s.aabb.area)
      const largerArea = Math.max(cand.aabb.area, s.aabb.area)
      const containment = smallerArea > 0 ? inter / smallerArea : 0
      const areaRatio = largerArea > 0 ? smallerArea / largerArea : 0

      if (iou > 0.6) { drop = true; break }
      if (containment > 0.8 && areaRatio >= 0.3 && areaRatio <= 0.7) {
        if (cand.aabb.area < s.aabb.area) { replaceIndex = i; break }
        drop = true
        break
      }
    }
    if (drop) continue
    if (replaceIndex >= 0) survivors[replaceIndex] = cand
    else survivors.push(cand)
  }
  return survivors
}

function findBestContour(cv, contours, imgArea, centerX, centerY) {
  const maxPossibleDist = Math.hypot(centerX, centerY)
  const candidates = []

  // Span of aspect deviation possible inside the gates [MIN_ASPECT, MAX_ASPECT],
  // used to normalize the aspect-fit term.
  const aspectFitSpan = Math.max(TARGET_ASPECT - MIN_ASPECT, MAX_ASPECT - TARGET_ASPECT)

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

    // Opposite-side ratio check — rejects trapezoids
    const widthRatio = Math.min(widthTop, widthBot) / Math.max(widthTop, widthBot)
    const heightRatio = Math.min(heightLeft, heightRight) / Math.max(heightLeft, heightRight)
    if (widthRatio < MIN_SIDE_RATIO || heightRatio < MIN_SIDE_RATIO) continue

    // Corner angle check — rejects non-rectangular quads
    const angles = [
      cornerAngle(ordered[3], ordered[0], ordered[1]),  // at TL
      cornerAngle(ordered[0], ordered[1], ordered[2]),  // at TR
      cornerAngle(ordered[1], ordered[2], ordered[3]),  // at BR
      cornerAngle(ordered[2], ordered[3], ordered[0]),  // at BL
    ]
    const maxAngleDev = Math.max(...angles.map(a => Math.abs(a - 90)))
    if (maxAngleDev > MAX_CORNER_DEVIATION) continue

    // Convexity check
    if (!isConvexQuad(ordered)) continue

    const rectScore = (widthRatio + heightRatio) / 2 * (1 - maxAngleDev / MAX_CORNER_DEVIATION)
    const cx = quad.reduce((s, p) => s + p.x, 0) / 4
    const cy = quad.reduce((s, p) => s + p.y, 0) / 4
    const d = Math.hypot(cx - centerX, cy - centerY)
    const normalizedDist = maxPossibleDist > 0 ? d / maxPossibleDist : 0
    const aspectFit = aspectFitSpan > 0
      ? Math.max(0, 1 - Math.abs(aspect - TARGET_ASPECT) / aspectFitSpan)
      : 1
    const compositeScore = rectScore * 0.5 + (1 - normalizedDist) * 0.3 + aspectFit * 0.2

    candidates.push({ ordered, score: compositeScore, area, aabb: quadAABB(ordered) })
  }

  const survivors = suppressCandidates(candidates)

  let bestQuad = null
  let bestScore = -Infinity
  let bestArea = 0
  for (const c of survivors) {
    if (c.score > bestScore) {
      bestScore = c.score
      bestQuad = c.ordered
      bestArea = c.area
    }
  }

  return { bestQuad, bestScore, bestArea }
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
    let bestScore = -Infinity

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
        cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE,
      )

      const result = findBestContour(cv, contours, imgArea, centerX, centerY)

      contours.delete()
      hierarchy.delete()
      contours = null
      hierarchy = null

      if (result.bestQuad && result.bestScore > bestScore) {
        bestQuad = result.bestQuad
        bestScore = result.bestScore
      }

      // Good enough — stop early (score > 0.85 means highly rectangular and near center)
      if (bestQuad && bestScore > 0.85) break
    }

    if (bestQuad) {
      // bestQuad is ordered [TL, TR, BR, BL]
      // Detect physical orientation from the quad's actual aspect — don't
      // force landscape into portrait, since horizontal cards (Everbloom,
      // Great Library of Solana) have art layouts that depend on it.
      const widthTop = dist(bestQuad[0], bestQuad[1])
      const heightLeft = dist(bestQuad[0], bestQuad[3])
      const layout = heightLeft >= widthTop ? "vertical" : "horizontal"

      const cardW = Math.round(widthTop)
      const cardH = Math.round(heightLeft)
      const srcCorners = bestQuad // TL, TR, BR, BL — preserved as detected

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

      // For vertical cards, use the pitch-strip saturation check to detect
      // upside-down captures. Horizontal cards (Everbloom split, Great
      // Library landmark) don't have a top-edge pitch strip, so skip the
      // check and let the backend's 4-way LEAST query absorb the flip.
      let orientation
      if (layout === "vertical") {
        orientation = detectOrientation(cardData, cardW, cardH)
        if (orientation === "flipped") {
          console.log(`${LOG} Card is upside-down — rotating 180°`)
          rotateBuffer180(cardData, cardW, cardH)
        }
      } else {
        orientation = "uncertain"
      }

      // Title + art regions only meaningful for vertical layouts. Horizontal
      // captures are split into halves by the hook.
      const title = layout === "vertical" ? {
        x: Math.round(cardW * TITLE_X_INSET),
        y: Math.round(cardH * TITLE_Y_RATIO),
        width: Math.round(cardW * (1 - 2 * TITLE_X_INSET)),
        height: Math.round(cardH * TITLE_H_RATIO),
      } : null

      const art = layout === "vertical" ? {
        x: Math.round(cardW * ART_X_INSET),
        y: Math.round(cardH * ART_Y_RATIO),
        width: Math.round(cardW * (1 - 2 * ART_X_INSET)),
        height: Math.round(cardH * ART_H_RATIO),
      } : null

      const cardArea = cardW * cardH
      console.log(`${LOG} Card: ${cardW}x${cardH} (${layout}), angle: ${angle.toFixed(1)}°, area: ${(cardArea / imgArea * 100).toFixed(1)}%, score: ${bestScore.toFixed(2)}`)
      if (title) console.log(`${LOG} Title: ${title.width}x${title.height} at (${title.x},${title.y})`)
      if (art) console.log(`${LOG} Art: ${art.width}x${art.height} at (${art.x},${art.y})`)

      self.postMessage({
        type: "cardDetected",
        requestId,
        card: { width: cardW, height: cardH },
        cardImageData: cardData.buffer,
        quad: bestQuad,
        layout,
        title,
        art,
        angle,
        orientation,
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
