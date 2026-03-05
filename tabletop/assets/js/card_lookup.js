// Card Lookup — client-side OCR for identifying cards in opponent's video feed
//
// Pipeline:
// 1. Capture a large region around the click from the remote canvas
// 2. Use OpenCV.js to detect rectangles and find the card + title bar
// 3. Crop just the title region, preprocess with OpenCV, and run Tesseract.js OCR
//
// Both OpenCV.js and Tesseract.js are loaded lazily from CDN on first use.
// Libraries are preloaded in parallel after the first click to speed up subsequent clicks.

const CAPTURE_SIZE = 500
const UPSCALE_FACTOR = 3
const LOG_PREFIX = "[CardLookup]"

// --- Timing helper ---

function timer(label) {
  const start = performance.now()
  return {
    done: () => {
      const ms = (performance.now() - start).toFixed(1)
      console.log(`${LOG_PREFIX} ${label}: ${ms}ms`)
      return parseFloat(ms)
    }
  }
}

// --- Lazy library loading ---

let _tesseractPromise = null
let _opencvPromise = null
let _workerPromise = null

function loadTesseract() {
  if (_tesseractPromise) return _tesseractPromise
  _tesseractPromise = new Promise((resolve, reject) => {
    if (window.Tesseract) return resolve(window.Tesseract)
    console.log(`${LOG_PREFIX} Loading Tesseract.js from CDN...`)
    const t = timer("Tesseract.js CDN load")
    const script = document.createElement("script")
    script.src = "https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js"
    script.onload = () => { t.done(); resolve(window.Tesseract) }
    script.onerror = () => { _tesseractPromise = null; reject(new Error("Failed to load Tesseract.js")) }
    document.head.appendChild(script)
  })
  return _tesseractPromise
}

function loadOpenCV() {
  if (_opencvPromise) return _opencvPromise
  _opencvPromise = new Promise((resolve, reject) => {
    if (window.cv && window.cv.Mat) {
      console.log(`${LOG_PREFIX} OpenCV.js already loaded`)
      return resolve(window.cv)
    }
    console.log(`${LOG_PREFIX} Loading OpenCV.js from CDN...`)
    const t = timer("OpenCV.js CDN load")

    // Use @techstark/opencv-js which has reliable WASM initialization
    window.cv = { onRuntimeInitialized: () => {
      console.log(`${LOG_PREFIX} OpenCV.js WASM runtime ready`)
      t.done()
      resolve(window.cv)
    }}

    const script = document.createElement("script")
    script.src = "https://cdn.jsdelivr.net/npm/@techstark/opencv-js@4.10.0-release.1/dist/opencv.js"
    script.async = true
    script.onerror = () => { _opencvPromise = null; reject(new Error("Failed to load OpenCV.js")) }
    document.head.appendChild(script)
  })
  return _opencvPromise
}

/**
 * Get or create a persistent Tesseract worker.
 * Caches the promise so concurrent callers share a single worker.
 */
function getTesseractWorker() {
  if (_workerPromise) return _workerPromise
  _workerPromise = (async () => {
    const Tesseract = await loadTesseract()
    console.log(`${LOG_PREFIX} Creating Tesseract worker + loading eng language data...`)
    const t = timer("Tesseract worker init")
    const worker = await Tesseract.createWorker("eng", 1, {
      logger: (info) => {
        if (info.status === "loading tesseract core" || info.status === "loading language traineddata") {
          console.log(`${LOG_PREFIX}   Worker: ${info.status} (${Math.round((info.progress || 0) * 100)}%)`)
        }
      },
    })
    await worker.setParameters({
      tessedit_pageseg_mode: "7",
      tessedit_char_whitelist: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '-,.",
    })
    t.done()
    return worker
  })()
  return _workerPromise
}

/**
 * Preload both libraries in parallel. Call this early (e.g. on page load or
 * first peer connection) so they're ready when the user clicks.
 */
export function preloadLibraries() {
  console.log(`${LOG_PREFIX} Preloading libraries in parallel...`)
  loadOpenCV().catch(() => {})
  getTesseractWorker().catch(() => {})
}

// --- OpenCV card detection ---

function detectCardRegions(captureCanvas) {
  const t = timer("OpenCV card detection")
  const cv = window.cv
  const src = cv.imread(captureCanvas)
  const gray = new cv.Mat()
  const blurred = new cv.Mat()
  const edges = new cv.Mat()
  const contours = new cv.MatVector()
  const hierarchy = new cv.Mat()

  let cardRect = null
  let titleRect = null
  const otherRects = []

  try {
    cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY)
    cv.GaussianBlur(gray, blurred, new cv.Size(5, 5), 0)
    cv.Canny(blurred, edges, 50, 150)

    const kernel = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(3, 3))
    cv.dilate(edges, edges, kernel)
    kernel.delete()

    cv.findContours(edges, contours, hierarchy, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE)

    const imgArea = captureCanvas.width * captureCanvas.height
    const numContours = contours.size()
    console.log(`${LOG_PREFIX}   Found ${numContours} contours`)

    let bestArea = 0

    for (let i = 0; i < numContours; i++) {
      const cnt = contours.get(i)
      const area = cv.contourArea(cnt)

      if (area < imgArea * 0.05 || area > imgArea * 0.95) continue

      const peri = cv.arcLength(cnt, true)
      const approx = new cv.Mat()
      cv.approxPolyDP(cnt, approx, 0.02 * peri, true)

      const rect = cv.boundingRect(cnt)
      const rectArea = rect.width * rect.height
      const rectangularity = area / rectArea
      const r = { x: rect.x, y: rect.y, w: rect.width, h: rect.height }

      if (approx.rows >= 4 && approx.rows <= 8 && rectangularity > 0.7 && rectArea > bestArea) {
        if (cardRect) otherRects.push(cardRect)
        bestArea = rectArea
        cardRect = r
      } else if (rectangularity > 0.5 && rectArea > imgArea * 0.02) {
        otherRects.push(r)
      }

      approx.delete()
    }

    if (cardRect) {
      const titleY = cardRect.y
      const titleH = Math.round(cardRect.h * 0.15)
      titleRect = { x: cardRect.x, y: titleY, w: cardRect.w, h: titleH }
      console.log(`${LOG_PREFIX}   Card found: ${cardRect.w}x${cardRect.h} at (${cardRect.x},${cardRect.y})`)
      console.log(`${LOG_PREFIX}   Title region: ${titleRect.w}x${titleRect.h} at (${titleRect.x},${titleRect.y})`)
    } else {
      console.log(`${LOG_PREFIX}   No card rectangle detected`)
    }
    console.log(`${LOG_PREFIX}   Other rects: ${otherRects.length}`)
  } finally {
    src.delete()
    gray.delete()
    blurred.delete()
    edges.delete()
    contours.delete()
    hierarchy.delete()
  }

  t.done()
  return { cardRect, titleRect, otherRects }
}

// --- Image preprocessing for OCR (using OpenCV for speed) ---

function preprocessForOCR(imageData) {
  const t = timer("Preprocess for OCR")
  const cv = window.cv

  // Put imageData into a canvas so OpenCV can read it
  const srcCanvas = document.createElement("canvas")
  srcCanvas.width = imageData.width
  srcCanvas.height = imageData.height
  srcCanvas.getContext("2d").putImageData(imageData, 0, 0)

  const src = cv.imread(srcCanvas)
  const gray = new cv.Mat()
  const resized = new cv.Mat()
  const sharpened = new cv.Mat()
  const blurForUnsharp = new cv.Mat()
  const binary = new cv.Mat()

  try {
    // Grayscale
    cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY)

    // Upscale
    const dstSize = new cv.Size(imageData.width * UPSCALE_FACTOR, imageData.height * UPSCALE_FACTOR)
    cv.resize(gray, resized, dstSize, 0, 0, cv.INTER_CUBIC)

    // Sharpen via unsharp mask: sharpened = src + amount * (src - blurred)
    cv.GaussianBlur(resized, blurForUnsharp, new cv.Size(0, 0), 1.0)
    cv.addWeighted(resized, 2.5, blurForUnsharp, -1.5, 0, sharpened)

    // Adaptive threshold
    cv.adaptiveThreshold(sharpened, binary, 255, cv.ADAPTIVE_THRESH_MEAN_C, cv.THRESH_BINARY, 91, 10)

    // Write result back to a canvas
    const outCanvas = document.createElement("canvas")
    cv.imshow(outCanvas, binary)
    t.done()
    return outCanvas
  } finally {
    src.delete()
    gray.delete()
    resized.delete()
    sharpened.delete()
    blurForUnsharp.delete()
    binary.delete()
  }
}

// --- Bounding box overlay ---

function showBoundingBox(container, canvasRect, cssX, cssY, cssW, cssH, isFlipped, color, label) {
  const box = document.createElement("div")
  const containerRect = container.getBoundingClientRect()
  let left = canvasRect.left - containerRect.left + cssX
  let top = canvasRect.top - containerRect.top + cssY
  if (isFlipped) {
    left = canvasRect.left - containerRect.left + (canvasRect.width - cssX - cssW)
    top = canvasRect.top - containerRect.top + (canvasRect.height - cssY - cssH)
  }
  box.style.cssText = `
    position: absolute;
    left: ${left}px; top: ${top}px;
    width: ${cssW}px; height: ${cssH}px;
    border: 2px solid ${color};
    border-radius: 4px;
    pointer-events: none;
    z-index: 45;
    transition: opacity 0.4s ease-out;
  `
  if (label) {
    const tag = document.createElement("span")
    tag.textContent = label
    tag.style.cssText = `
      position: absolute; top: -18px; left: 0;
      font-size: 10px; line-height: 1;
      padding: 1px 4px; border-radius: 2px;
      background: ${color}; color: #000;
      white-space: nowrap; font-weight: 600;
    `
    box.appendChild(tag)
  }
  container.appendChild(box)
  return box
}

// --- Main export ---

export async function captureAndOCR(canvasEl, clientX, clientY, isFlipped, container) {
  const totalTimer = timer("Total captureAndOCR")

  const rect = canvasEl.getBoundingClientRect()
  const scaleX = canvasEl.width / rect.width
  const scaleY = canvasEl.height / rect.height

  let canvasX = (clientX - rect.left) * scaleX
  let canvasY = (clientY - rect.top) * scaleY

  if (isFlipped) {
    canvasX = canvasEl.width - canvasX
    canvasY = canvasEl.height - canvasY
  }

  const half = CAPTURE_SIZE / 2
  const sx = Math.max(0, Math.round(canvasX - half))
  const sy = Math.max(0, Math.round(canvasY - half))
  const sw = Math.min(CAPTURE_SIZE, canvasEl.width - sx)
  const sh = Math.min(CAPTURE_SIZE, canvasEl.height - sy)
  if (sw <= 0 || sh <= 0) return ""

  // Step 1: Capture
  const t1 = timer("Canvas capture")
  const ctx = canvasEl.getContext("2d")
  const imageData = ctx.getImageData(sx, sy, sw, sh)
  const captureCanvas = document.createElement("canvas")
  captureCanvas.width = sw
  captureCanvas.height = sh
  captureCanvas.getContext("2d").putImageData(imageData, 0, 0)
  t1.done()

  // Step 2: Load libraries in parallel
  const t2 = timer("Load libraries")
  console.log(`${LOG_PREFIX} Loading OpenCV + Tesseract worker in parallel...`)
  const [cv, worker] = await Promise.all([
    loadOpenCV(),
    getTesseractWorker(),
  ])
  t2.done()
  console.log(`${LOG_PREFIX} Libraries ready. cv.Mat exists: ${!!cv.Mat}, worker: ${!!worker}`)

  // Step 3: OpenCV card detection
  console.log(`${LOG_PREFIX} Starting card detection...`)
  const { cardRect, titleRect, otherRects } = detectCardRegions(captureCanvas)
  console.log(`${LOG_PREFIX} Card detection complete.`)

  // Step 4: Show bounding boxes
  const boxes = []
  const addBox = (region, color, label) => {
    if (!container || !region) return
    const cssX = (sx + region.x) / scaleX
    const cssY = (sy + region.y) / scaleY
    const cssW = region.w / scaleX
    const cssH = region.h / scaleY
    boxes.push(showBoundingBox(container, rect, cssX, cssY, cssW, cssH, isFlipped, color, label))
  }

  if (container) {
    const capBox = showBoundingBox(
      container, rect, sx / scaleX, sy / scaleY, sw / scaleX, sh / scaleY,
      isFlipped, "rgba(255,255,255,0.4)", "capture"
    )
    capBox.style.borderStyle = "dashed"
    boxes.push(capBox)
  }
  for (const r of otherRects) addBox(r, "oklch(0.8 0.18 90)", null)
  addBox(cardRect, "oklch(0.75 0.15 195)", "card")
  addBox(titleRect, "oklch(0.75 0.18 145)", "title")

  // Step 5: Crop the OCR region
  let ocrImageData
  if (titleRect) {
    ocrImageData = captureCanvas.getContext("2d").getImageData(titleRect.x, titleRect.y, titleRect.w, titleRect.h)
    console.log(`${LOG_PREFIX} OCR region: ${titleRect.w}x${titleRect.h} (title)`)
  } else {
    const fallbackH = Math.min(80, sh)
    const fallbackY = Math.max(0, Math.round(sh / 2 - fallbackH / 2))
    ocrImageData = captureCanvas.getContext("2d").getImageData(0, fallbackY, sw, fallbackH)
    console.log(`${LOG_PREFIX} OCR region: ${sw}x${fallbackH} (fallback center strip)`)
  }

  // Step 6: Preprocess with OpenCV
  console.log(`${LOG_PREFIX} Starting preprocessing...`)
  const processedCanvas = preprocessForOCR(ocrImageData)
  console.log(`${LOG_PREFIX} Preprocessing done, canvas: ${processedCanvas.width}x${processedCanvas.height}`)

  // Step 7: Convert to data URL for Tesseract (cv.imshow canvases can cause issues)
  const t6b = timer("Canvas to data URL")
  const dataUrl = processedCanvas.toDataURL("image/png")
  t6b.done()
  console.log(`${LOG_PREFIX} Data URL length: ${dataUrl.length}`)

  // Step 8: OCR
  try {
    const t7 = timer("Tesseract OCR recognize")
    console.log(`${LOG_PREFIX} Running Tesseract OCR on data URL...`)
    const result = await worker.recognize(dataUrl)
    t7.done()

    const text = result.data.text.trim().replace(/\n/g, " ").replace(/\s+/g, " ")
    console.log(`${LOG_PREFIX} OCR result: "${text}" (confidence: ${result.data.confidence})`)
    totalTimer.done()
    return text
  } finally {
    for (const box of boxes) {
      box.style.opacity = "0"
      setTimeout(() => box.remove(), 400)
    }
  }
}
