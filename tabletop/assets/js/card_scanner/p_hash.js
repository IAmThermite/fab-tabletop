// Perceptual hash (pHash) — DCT-based 64-bit image fingerprint.
//
// Algorithm:
// 1. Resize to 32x32 grayscale (area-average downsampling)
// 2. Compute 2D DCT
// 3. Take top-left 8x8 low-frequency block (excluding DC)
// 4. Hash: each bit = 1 if coefficient > median, else 0
//
// Operates on `ImageData`-shaped objects (`{data, width, height}`) so it can
// run in Node tests without a `<canvas>` polyfill. The browser callers pass
// `ImageData` directly (e.g. from `getImageData()` or transferred from a
// worker); a thin `computePHashFromCanvas` shim is provided for any code that
// only has a canvas handy.

const HASH_SIZE = 8
const DCT_SIZE = 32

// Precompute DCT cosine table.
const cosTable = new Float64Array(DCT_SIZE * DCT_SIZE)
for (let i = 0; i < DCT_SIZE; i++) {
  for (let j = 0; j < DCT_SIZE; j++) {
    cosTable[i * DCT_SIZE + j] = Math.cos(((2 * j + 1) * i * Math.PI) / (2 * DCT_SIZE))
  }
}

// Area-average downsample to 32x32 grayscale.
//
// `image`: { data: Uint8ClampedArray (RGBA), width, height }
// `region`: optional { x, y, width, height } in source pixel coordinates.
//
// Returns Float64Array of DCT_SIZE*DCT_SIZE grayscale values.
function resizeToGray(image, region) {
  const N = DCT_SIZE
  const { data, width, height } = image
  const sx0 = region ? region.x : 0
  const sy0 = region ? region.y : 0
  const sw = region ? region.width : width
  const sh = region ? region.height : height
  const gray = new Float64Array(N * N)

  for (let oy = 0; oy < N; oy++) {
    const fy0 = sy0 + (oy * sh) / N
    const fy1 = sy0 + ((oy + 1) * sh) / N
    const y0 = Math.max(0, Math.floor(fy0))
    const y1 = Math.max(y0 + 1, Math.min(height, Math.ceil(fy1)))

    for (let ox = 0; ox < N; ox++) {
      const fx0 = sx0 + (ox * sw) / N
      const fx1 = sx0 + ((ox + 1) * sw) / N
      const x0 = Math.max(0, Math.floor(fx0))
      const x1 = Math.max(x0 + 1, Math.min(width, Math.ceil(fx1)))

      let sumR = 0, sumG = 0, sumB = 0, count = 0
      for (let sy = y0; sy < y1; sy++) {
        const rowOffset = sy * width * 4
        for (let sx = x0; sx < x1; sx++) {
          const idx = rowOffset + sx * 4
          sumR += data[idx]
          sumG += data[idx + 1]
          sumB += data[idx + 2]
          count++
        }
      }

      const r = sumR / count
      const g = sumG / count
      const b = sumB / count
      gray[oy * N + ox] = 0.299 * r + 0.587 * g + 0.114 * b
    }
  }

  return gray
}

function dct2d(gray) {
  const N = DCT_SIZE
  // Row-wise DCT
  const rowDCT = new Float64Array(N * N)
  for (let y = 0; y < N; y++) {
    for (let u = 0; u < N; u++) {
      let sum = 0
      for (let x = 0; x < N; x++) {
        sum += gray[y * N + x] * cosTable[u * N + x]
      }
      rowDCT[y * N + u] = sum
    }
  }
  // Column-wise DCT
  const result = new Float64Array(N * N)
  for (let u = 0; u < N; u++) {
    for (let v = 0; v < N; v++) {
      let sum = 0
      for (let y = 0; y < N; y++) {
        sum += rowDCT[y * N + u] * cosTable[v * N + y]
      }
      result[v * N + u] = sum
    }
  }
  return result
}

// Compute a 64-bit pHash for an `ImageData`-shaped image, optionally
// restricted to a `{x, y, width, height}` region in source pixel coordinates.
//
// Returns BigInt.
export function computePHash(image, region) {
  const gray = resizeToGray(image, region)
  const dct = dct2d(gray)

  // Extract top-left 8x8 block (excluding DC at [0,0]).
  const coeffs = []
  for (let y = 0; y < HASH_SIZE; y++) {
    for (let x = 0; x < HASH_SIZE; x++) {
      if (x === 0 && y === 0) continue
      coeffs.push(dct[y * DCT_SIZE + x])
    }
  }

  // Median.
  const sorted = [...coeffs].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  const median = sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid]

  // Build 64-bit hash as BigInt (DC bit is always 0).
  let hash = 0n
  for (const c of coeffs) {
    hash = (hash << 1n) | (c > median ? 1n : 0n)
  }

  return hash
}

// Browser convenience wrapper — extracts ImageData from a canvas and forwards.
export function computePHashFromCanvas(canvas, region) {
  const ctx = canvas.getContext("2d")
  const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height)
  return computePHash(imageData, region)
}

export function hammingDistance(a, b) {
  let dist = 0
  let xor = a ^ b
  while (xor !== 0n) {
    xor &= xor - 1n
    dist++
  }
  return dist
}
