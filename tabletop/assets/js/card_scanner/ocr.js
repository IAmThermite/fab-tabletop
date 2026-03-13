// Tesseract.js OCR — lazy CDN loading with cached worker promise

const LOG = "[CardScanner:OCR]"

let _tesseractPromise = null
let _workerPromise = null

function loadTesseract() {
  if (_tesseractPromise) return _tesseractPromise
  _tesseractPromise = new Promise((resolve, reject) => {
    if (window.Tesseract) return resolve(window.Tesseract)
    console.log(`${LOG} Loading Tesseract.js from CDN...`)
    const script = document.createElement("script")
    script.src = "https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js"
    script.onload = () => resolve(window.Tesseract)
    script.onerror = () => {
      _tesseractPromise = null
      reject(new Error("Failed to load Tesseract.js"))
    }
    document.head.appendChild(script)
  })
  return _tesseractPromise
}

function getWorker() {
  if (_workerPromise) return _workerPromise
  _workerPromise = (async () => {
    const Tesseract = await loadTesseract()
    console.log(`${LOG} Creating Tesseract worker...`)
    const worker = await Tesseract.createWorker("eng", 1, {
      logger: (info) => {
        if (
          info.status === "loading tesseract core" ||
          info.status === "loading language traineddata"
        ) {
          console.log(
            `${LOG}   Worker: ${info.status} (${Math.round((info.progress || 0) * 100)}%)`,
          )
        }
      },
    })
    // PSM 7 = single text line
    await worker.setParameters({
      tessedit_pageseg_mode: "7",
      tessedit_char_whitelist: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    })
    return worker
  })()
  return _workerPromise
}

export function preloadOCR() {
  getWorker().catch(() => {})
}

export async function runOCR(canvas) {
  const worker = await getWorker()
  console.log(`${LOG} Running OCR (${canvas.width}x${canvas.height})...`)
  const dataUrl = canvas.toDataURL("image/png")
  const result = await worker.recognize(dataUrl, "eng")
  const text = result.data.text.trim().replace(/\n/g, " ").replace(/\s+/g, " ")
  const confidence = result.data.confidence
  console.log(`${LOG} OCR result: "${text}" (confidence: ${confidence})`)
  return { text, confidence }
}
