// Post-deskew recognition pipeline — shared between scan-time runtime and the
// fixture-driven JS test suite. Operates on `ImageData`-shaped objects
// (`{data: Uint8ClampedArray, width, height}`) so it has no DOM dependency.
//
// Inputs:
//   * `deskewedImageData`   — the deskewed card pixels emitted by the OpenCV
//                             worker (or a pre-cropped fixture in the test).
//   * `{ layout, art }`     — `layout` is `"vertical"` or `"horizontal"`;
//                             `art` is the fixed art rect for vertical
//                             layouts (or `null` for horizontal).
//   * `orientation`         — `"upright" | "flipped" | "uncertain"` from the
//                             worker. When `"uncertain"` for vertical
//                             captures we also include an `art_flipped` hash.
//
// Output:
//   `[{ kind, value, imageData }]` — `kind` is one of the wire-format kinds
//   (`art`, `art_flipped`, `art_left`, `art_right`, `full`); `value` is a
//   BigInt; `imageData` is the exact pixels that were hashed (used by the
//   debug panel).

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

// Rotate an ImageData 90° counter-clockwise. Matches how the cardvault API
// stores horizontal cards (rotated CCW into a portrait file).
export function rotated90CCWImageData(src) {
  const sw = src.width
  const sh = src.height
  const dw = sh
  const dh = sw
  const out = new Uint8ClampedArray(dw * dh * 4)
  for (let y = 0; y < sh; y++) {
    for (let x = 0; x < sw; x++) {
      // 90° CCW: src(x, y) → dst(y, sw - 1 - x)
      const dx = y
      const dy = sw - 1 - x
      const sIdx = (y * sw + x) * 4
      const dIdx = (dy * dw + dx) * 4
      out[dIdx] = src.data[sIdx]
      out[dIdx + 1] = src.data[sIdx + 1]
      out[dIdx + 2] = src.data[sIdx + 2]
      out[dIdx + 3] = src.data[sIdx + 3]
    }
  }
  return { data: out, width: dw, height: dh }
}

// Build the `phashes` payload for a deskewed card. Mirrors the SQL query's
// expectations:
//   * vertical → `art` + `art_flipped` + `full` (always send both
//                 orientations — the detector isn't reliable enough to skip
//                 the flipped variant)
//   * horizontal → portrait-rotate, then `art` + `art_flipped` (vertical-card
//                  hashes for cards laid sideways) + `art_left` + `art_right`
//                  (true-horizontal halves) + `full`
export function computePhashesForLayout(deskewedImageData, options = {}) {
  const { layout, art } = options
  const phashes = []

  let fullSource = deskewedImageData

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

      // Always send the flipped variant — the orientation detector isn't
      // reliable enough to skip it when "upright"; the backend's per-kind
      // threshold absorbs the extra pairing for free.
      const flipped = rotated180ImageData(deskewedImageData)
      const artFlipped = cropImageData(flipped, region)
      phashes.push({
        kind: "art_flipped",
        value: computePHash(artFlipped),
        imageData: artFlipped,
      })
    }
  } else if (layout === "horizontal") {
    // Rotate the landscape capture 90° CCW into portrait orientation. This
    // serves two cases at once:
    //   - True horizontal cards (Everbloom, Great Library) are stored
    //     portrait in the cardvault API; rotating aligns capture with stored
    //     halves.
    //   - Vertical cards laid sideways on the table are detected as
    //     horizontal by the quad aspect; rotating gives an upright portrait
    //     that matches stored vertical `image_phash` / `full`.
    const portrait = rotated90CCWImageData(deskewedImageData)
    fullSource = portrait
    const pw = portrait.width
    const ph = portrait.height

    const artBbox = {
      x: Math.round(pw * VERTICAL_FALLBACK_ART.xInset),
      y: Math.round(ph * VERTICAL_FALLBACK_ART.yRatio),
      width: Math.round(pw * (1 - 2 * VERTICAL_FALLBACK_ART.xInset)),
      height: Math.round(ph * VERTICAL_FALLBACK_ART.hRatio),
    }

    const artImage = cropImageData(portrait, artBbox)
    phashes.push({ kind: "art", value: computePHash(artImage), imageData: artImage })

    const portraitFlipped = rotated180ImageData(portrait)
    const artFlippedImage = cropImageData(portraitFlipped, artBbox)
    phashes.push({
      kind: "art_flipped",
      value: computePHash(artFlippedImage),
      imageData: artFlippedImage,
    })

    const halfH = Math.floor(ph / 2)
    const top = cropImageData(portrait, { x: 0, y: 0, width: pw, height: halfH })
    const bottom = cropImageData(portrait, {
      x: 0,
      y: halfH,
      width: pw,
      height: ph - halfH,
    })
    phashes.push({ kind: "art_left", value: computePHash(top), imageData: top })
    phashes.push({ kind: "art_right", value: computePHash(bottom), imageData: bottom })
  }

  // Whole-card hash — fallback / tiebreaker. For horizontal layouts we hash
  // the rotated portrait so it can match the portrait-stored full hash.
  phashes.push({
    kind: "full",
    value: computePHash(fullSource),
    imageData: fullSource,
  })

  return phashes
}
