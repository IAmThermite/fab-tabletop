// Post-deskew recognition pipeline — shared between scan-time runtime and the
// fixture-driven JS test suite. Operates on `ImageData`-shaped objects
// (`{data: Uint8ClampedArray, width, height}`) so it has no DOM dependency.
//
// Horizontal captures are rotated to portrait by the OpenCV worker, so by the
// time pixels reach here every card is treated as vertical.
//
// Inputs:
//   * `deskewedImageData`   — the deskewed, upright card pixels emitted by the
//                             OpenCV worker (or a pre-cropped fixture in the
//                             test).
//   * `{ layout, art }`     — `layout` is `"vertical"`; `art` is the fixed art
//                             rect (or `null` to use the fallback ratios).
//   * `orientation`         — `"upright" | "flipped" | "uncertain"` from the
//                             worker. We always include an `art_flipped` hash
//                             since the orientation detector isn't reliable
//                             enough to skip it.
//
// Output:
//   `[{ kind, value, imageData }]` — `kind` is one of the wire-format kinds
//   (`art`, `art_flipped`, `full`); `value` is a BigInt; `imageData` is the
//   exact pixels that were hashed (used by the debug panel).

import { computePHash } from "./p_hash.js"

const VERTICAL_FALLBACK_ART = { yRatio: 0.16, hRatio: 0.42, xInset: 0.10 }

// Crop a region of an ImageData into a new ImageData-shaped object.
export function cropImageData(src, region) {
  const { x, y, width, height } = region
  const out = new Uint8ClampedArray(width * height * 4)
  for (let row = 0; row < height; row++) {
    const srcStart = ((y + row) * src.width + x) * 4
    const srcEnd = srcStart + width * 4
    out.set(src.data.subarray(srcStart, srcEnd), row * width * 4)
  }
  return { data: out, width, height }
}

// Rotate an ImageData 180° into a new ImageData-shaped object.
export function rotated180ImageData(src) {
  const { width, height } = src
  const out = new Uint8ClampedArray(src.data.length)
  const total = width * height
  for (let i = 0; i < total; i++) {
    const j = total - 1 - i
    const si = i * 4
    const di = j * 4
    out[di] = src.data[si]
    out[di + 1] = src.data[si + 1]
    out[di + 2] = src.data[si + 2]
    out[di + 3] = src.data[si + 3]
  }
  return { data: out, width, height }
}

// Build the `phashes` payload for a deskewed card: `art` + `art_flipped` +
// `full`. Both orientations of the art are always sent — the orientation
// detector isn't reliable enough to skip the flipped variant, and the
// backend's per-kind threshold absorbs the extra pairing for free.
export function computePhashesForLayout(deskewedImageData, options = {}) {
  const { layout, art } = options
  const phashes = []

  if (layout === "vertical") {
    const cardW = deskewedImageData.width
    const cardH = deskewedImageData.height

    const region = art ? {
      x: art.x,
      y: art.y,
      width: Math.min(art.width, cardW - art.x),
      height: Math.min(art.height, cardH - art.y),
    } : {
      x: Math.round(cardW * VERTICAL_FALLBACK_ART.xInset),
      y: Math.round(cardH * VERTICAL_FALLBACK_ART.yRatio),
      width: Math.round(cardW * (1 - 2 * VERTICAL_FALLBACK_ART.xInset)),
      height: Math.round(cardH * VERTICAL_FALLBACK_ART.hRatio),
    }

    if (region.width > 20 && region.height > 20) {
      const artImage = cropImageData(deskewedImageData, region)
      phashes.push({ kind: "art", value: computePHash(artImage), imageData: artImage })

      const flipped = rotated180ImageData(deskewedImageData)
      const artFlipped = cropImageData(flipped, region)
      phashes.push({
        kind: "art_flipped",
        value: computePHash(artFlipped),
        imageData: artFlipped,
      })
    }
  }

  // Whole-card hash — fallback / tiebreaker.
  phashes.push({
    kind: "full",
    value: computePHash(deskewedImageData),
    imageData: deskewedImageData,
  })

  return phashes
}
