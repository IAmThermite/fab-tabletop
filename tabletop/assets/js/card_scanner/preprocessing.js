// Canvas-based image preprocessing for OCR
// Pipeline: grayscale → unsharp mask → nearest-neighbour upscale → adaptive threshold

const UPSCALE = 3

// Integral image (summed area table) for O(1) local mean computation
function integralImage(src, w, h) {
  const sat = new Float64Array((w + 1) * (h + 1))
  const sw = w + 1
  for (let y = 0; y < h; y++) {
    let rowSum = 0
    for (let x = 0; x < w; x++) {
      rowSum += src[y * w + x]
      sat[(y + 1) * sw + (x + 1)] = rowSum + sat[y * sw + (x + 1)]
    }
  }
  return sat
}

function localMeanFromSAT(sat, w, h, x, y, radius) {
  const sw = w + 1
  const x0 = Math.max(0, x - radius)
  const y0 = Math.max(0, y - radius)
  const x1 = Math.min(w, x + radius + 1)
  const y1 = Math.min(h, y + radius + 1)
  const sum = sat[y1 * sw + x1] - sat[y0 * sw + x1] - sat[y1 * sw + x0] + sat[y0 * sw + x0]
  return sum / ((x1 - x0) * (y1 - y0))
}

export function preprocessForOCR(imageData) {
  const w = imageData.width
  const h = imageData.height

  // Keep raw capture for debug
  const rawCanvas = document.createElement("canvas")
  rawCanvas.width = w
  rawCanvas.height = h
  rawCanvas.getContext("2d").putImageData(
    new ImageData(new Uint8ClampedArray(imageData.data), w, h), 0, 0,
  )

  const data = imageData.data

  // Step 1: Grayscale
  const gray = new Float32Array(w * h)
  for (let i = 0; i < w * h; i++) {
    const j = i * 4
    gray[i] = 0.299 * data[j] + 0.587 * data[j + 1] + 0.114 * data[j + 2]
  }

  // Step 2: Sharpen via 3x3 unsharp mask (amount = 2.0)
  const sharpened = new Float32Array(w * h)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const idx = y * w + x
      let sum = 0, count = 0
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx, ny = y + dy
          if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
            sum += gray[ny * w + nx]
            count++
          }
        }
      }
      const blurred = sum / count
      let v = gray[idx] + 2.0 * (gray[idx] - blurred)
      sharpened[idx] = v < 0 ? 0 : v > 255 ? 255 : v
    }
  }

  // Write sharpened grayscale to canvas for debug
  const grayCanvas = document.createElement("canvas")
  grayCanvas.width = w
  grayCanvas.height = h
  const grayCtx = grayCanvas.getContext("2d")
  const grayImgData = grayCtx.createImageData(w, h)
  for (let i = 0; i < w * h; i++) {
    const v = Math.round(sharpened[i])
    grayImgData.data[i * 4] = v
    grayImgData.data[i * 4 + 1] = v
    grayImgData.data[i * 4 + 2] = v
    grayImgData.data[i * 4 + 3] = 255
  }
  grayCtx.putImageData(grayImgData, 0, 0)

  // Step 2b: Adaptive threshold on the sharpened grayscale (no upscale)
  const sharpThreshCanvas = document.createElement("canvas")
  sharpThreshCanvas.width = w
  sharpThreshCanvas.height = h
  const sharpThreshCtx = sharpThreshCanvas.getContext("2d")
  const sharpThreshData = sharpThreshCtx.createImageData(w, h)
  const stSAT = integralImage(sharpened, w, h)
  const stRadius = Math.max(4, Math.round(w / 10))
  const stBias = 15
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x
      const mean = localMeanFromSAT(stSAT, w, h, x, y, stRadius)
      const v = sharpened[i] < (mean - stBias) ? 0 : 255
      sharpThreshData.data[i * 4] = v
      sharpThreshData.data[i * 4 + 1] = v
      sharpThreshData.data[i * 4 + 2] = v
      sharpThreshData.data[i * 4 + 3] = 255
    }
  }
  sharpThreshCtx.putImageData(sharpThreshData, 0, 0)

  // Step 3: Upscale (nearest neighbour — no smoothing, keeps edges sharp)
  const outW = w * UPSCALE
  const outH = h * UPSCALE
  const upCanvas = document.createElement("canvas")
  upCanvas.width = outW
  upCanvas.height = outH
  const upCtx = upCanvas.getContext("2d")
  upCtx.imageSmoothingEnabled = false
  upCtx.drawImage(grayCanvas, 0, 0, outW, outH)

  // Keep a copy of the upscaled grayscale before thresholding
  const upGrayCanvas = document.createElement("canvas")
  upGrayCanvas.width = outW
  upGrayCanvas.height = outH
  upGrayCanvas.getContext("2d").drawImage(upCanvas, 0, 0)

  // Step 4: Adaptive threshold using integral image (O(1) per pixel)
  const upData = upCtx.getImageData(0, 0, outW, outH)
  const upPx = upData.data
  const upGray = new Float32Array(outW * outH)
  for (let i = 0; i < outW * outH; i++) {
    upGray[i] = upPx[i * 4]
  }

  const sat = integralImage(upGray, outW, outH)
  const blockRadius = Math.max(8, Math.round(outW / 10))
  const bias = 12

  for (let y = 0; y < outH; y++) {
    for (let x = 0; x < outW; x++) {
      const i = y * outW + x
      const mean = localMeanFromSAT(sat, outW, outH, x, y, blockRadius)
      const v = upGray[i] < (mean - bias) ? 0 : 255
      upPx[i * 4] = v
      upPx[i * 4 + 1] = v
      upPx[i * 4 + 2] = v
    }
  }
  upCtx.putImageData(upData, 0, 0)

  return { processedCanvas: upCanvas, rawCanvas, grayCanvas, upGrayCanvas, sharpThreshCanvas }
}

// Rotate a canvas 90 degrees CW or CCW
export function rotateCanvas90(canvas, direction = "cw") {
  const rotated = document.createElement("canvas")
  rotated.width = canvas.height
  rotated.height = canvas.width
  const ctx = rotated.getContext("2d")
  ctx.translate(rotated.width / 2, rotated.height / 2)
  ctx.rotate(direction === "cw" ? Math.PI / 2 : -Math.PI / 2)
  ctx.drawImage(canvas, -canvas.width / 2, -canvas.height / 2)
  return rotated
}

// Convert an `ImageData` (or `{data, width, height}` duck-type) to a canvas.
// The recognition pipeline emits the duck-type for portability with Node
// tests; this helper bridges back to a real canvas for browser-side use.
export function imageDataToCanvas(imageData) {
  const c = document.createElement("canvas")
  c.width = imageData.width
  c.height = imageData.height
  const real = imageData instanceof ImageData
    ? imageData
    : new ImageData(imageData.data, imageData.width, imageData.height)
  c.getContext("2d").putImageData(real, 0, 0)
  return c
}

// Crop margins from processed image (removes edge noise artifacts)
export function cropMargins(canvas) {
  const margin = Math.round(UPSCALE * 4)
  const cropW = canvas.width - margin * 2
  const cropH = canvas.height - margin * 2
  if (cropW <= 50 || cropH <= 20) return canvas

  const cropped = document.createElement("canvas")
  cropped.width = cropW
  cropped.height = cropH
  cropped.getContext("2d").drawImage(
    canvas, margin, margin, cropW, cropH, 0, 0, cropW, cropH,
  )
  return cropped
}
