// Perceptual hash (pHash) — DCT-based 64-bit image fingerprint
//
// Algorithm:
// 1. Resize to 32x32 grayscale
// 2. Compute 2D DCT
// 3. Take top-left 8x8 low-frequency block
// 4. Hash: each bit = 1 if coefficient > median, else 0

const HASH_SIZE = 8
const DCT_SIZE = 32

// Precompute DCT cosine table
const cosTable = new Float64Array(DCT_SIZE * DCT_SIZE)
for (let i = 0; i < DCT_SIZE; i++) {
  for (let j = 0; j < DCT_SIZE; j++) {
    cosTable[i * DCT_SIZE + j] = Math.cos(((2 * j + 1) * i * Math.PI) / (2 * DCT_SIZE))
  }
}

function resizeToGray(canvas) {
  const tmp = document.createElement("canvas")
  tmp.width = DCT_SIZE
  tmp.height = DCT_SIZE
  const ctx = tmp.getContext("2d")
  ctx.imageSmoothingEnabled = true
  ctx.imageSmoothingQuality = "high"
  ctx.drawImage(canvas, 0, 0, DCT_SIZE, DCT_SIZE)
  const { data } = ctx.getImageData(0, 0, DCT_SIZE, DCT_SIZE)
  const gray = new Float64Array(DCT_SIZE * DCT_SIZE)
  for (let i = 0; i < DCT_SIZE * DCT_SIZE; i++) {
    const j = i * 4
    gray[i] = 0.299 * data[j] + 0.587 * data[j + 1] + 0.114 * data[j + 2]
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

export function computePHash(canvas) {
  const gray = resizeToGray(canvas)
  const dct = dct2d(gray)

  // Extract top-left 8x8 block (excluding DC at [0,0])
  const coeffs = []
  for (let y = 0; y < HASH_SIZE; y++) {
    for (let x = 0; x < HASH_SIZE; x++) {
      if (x === 0 && y === 0) continue
      coeffs.push(dct[y * DCT_SIZE + x])
    }
  }

  // Median
  const sorted = [...coeffs].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  const median = sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid]

  // Build 64-bit hash (DC bit is always 0)
  let hash = ""
  let bits = ""
  bits += "0" // DC coefficient placeholder
  for (const c of coeffs) {
    bits += c > median ? "1" : "0"
  }

  // Convert 64 bits to 16-char hex
  for (let i = 0; i < 64; i += 4) {
    hash += parseInt(bits.slice(i, i + 4), 2).toString(16)
  }

  return hash
}

export function hammingDistance(a, b) {
  if (a.length !== b.length) return 64
  let dist = 0
  for (let i = 0; i < a.length; i++) {
    const x = parseInt(a[i], 16) ^ parseInt(b[i], 16)
    // Count bits in nibble
    dist += ((x >> 3) & 1) + ((x >> 2) & 1) + ((x >> 1) & 1) + (x & 1)
  }
  return dist
}
