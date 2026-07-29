// Canvas helpers for the card scanner.

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
