# Frontend Card Recognition Pipeline

This document outlines the end-to-end flow of the frontend card recognition system, from user interaction to backend payload generation.

## Overview

The card recognition system uses a multi-stage pipeline combining OpenCV for card detection, Tesseract.js for OCR text recognition, and perceptual hashing (pHash) for image-based card identification. The system handles both vertical and horizontal card layouts, with automatic orientation detection.

## Architecture

```
User Click → LiveView Hook → OpenCV Worker → Recognition Pipeline → Backend Payload
                      ↓              ↓                ↓
                   Capture Region   Deskew         pHash + OCR
                      ↓              ↓                ↓
                   Preprocessing    Orientation    Pitch Detection
```

## Module Overview

- **`liveview_hook.js`** - Main entry point, coordinates the pipeline and handles user interaction
- **`scanner_worker.js`** - OpenCV web worker for card detection and deskewing
- **`recognition_pipeline.js`** - Post-deskew processing and perceptual hashing
- **`preprocessing.js`** - Image preprocessing for OCR
- **`p_hash.js`** - DCT-based 64-bit perceptual hashing algorithm
- **`ocr.js`** - Tesseract.js integration for text recognition
- **`debug.js`** - Debug visualization panel

## End-to-End Flow

### 1. User Interaction (`liveview_hook.js`)

When a user clicks on the game area canvas:

```javascript
gameArea.addEventListener("click", async (e) => {
  // Show loading indicator
  showLoading(e.clientX, e.clientY)
  
  // Capture and process the card
  const result = await captureAndOCR(canvasEl, e.clientX, e.clientY, isFlipped(), gameArea)
  
  // Send results to backend
  if (result) {
    hook.pushEvent("open_card", payload)
  }
})
```

**Key steps:**
- Convert click coordinates from CSS pixels to canvas pixels
- Handle camera flip (if applicable)
- Capture a square region around the click (35% of canvas dimensions)
- Display loading indicator

### 2. Card Detection (`scanner_worker.js`)

The OpenCV worker receives the captured region and performs card detection:

#### 2.1 Edge Detection Strategies

Multiple edge detection strategies are tried to handle different lighting conditions:

```javascript
const strategies = [
  { blur: 5, cannyLow: 30, cannyHigh: 100, dilations: 2 },
  { blur: 5, cannyLow: 15, cannyHigh: 60,  dilations: 2 },
  { blur: 3, cannyLow: 50, cannyHigh: 150, dilations: 1 },
  { blur: 7, cannyLow: 20, cannyHigh: 80,  dilations: 3 },
]
```

For each strategy:
1. Apply Gaussian blur
2. Apply Canny edge detection
3. Dilate edges to close gaps
4. Find contours

#### 2.2 Contour Filtering

Contours are filtered using multiple criteria:

- **Area ratio**: Card must be 5-60% of image area
- **Aspect ratio**: Long/short side must be between 1.1-2.0 (standard FaB cards ~1.4)
- **Rectangularity**: Opposite sides must be within 75% of each other
- **Corner angles**: All corners must be within 25° of 90°
- **Convexity**: Quad must be convex

#### 2.3 Quad Detection

For each contour:
1. Use `approxPolyDP` to find 4-point polygon approximation
2. Try multiple epsilon values (0.02-0.10) to find best quad
3. Order corners as [top-left, top-right, bottom-right, bottom-left]

#### 2.4 Non-Maximum Suppression

Greedy suppression removes duplicate detections:
- High IoU (>0.6): Keep higher-scored quad
- High containment (>0.8) with 30-70% area ratio: Prefer smaller quad (catches merged two-card blobs)

#### 2.5 Perspective Transform

Once the best quad is found:
1. Compute source corners from detected quad
2. Compute destination corners as upright rectangle
3. Apply perspective transform to deskew the card
4. Extract deskewed card as RGBA ImageData

#### 2.6 Layout Detection

Layout is determined by comparing width and height:

```javascript
const layout = heightLeft >= widthTop ? "vertical" : "horizontal"
```

- **Vertical**: Standard portrait cards (most FaB cards)
- **Horizontal**: Landscape cards (Everbloom, Great Library) or vertical cards laid sideways

#### 2.7 Orientation Detection (Vertical Only)

For vertical cards, detect if the card is upside-down by comparing color saturation:

```javascript
function detectOrientation(cardData, cardW, cardH) {
  // Sample top 1-4% and bottom 96-99% strips
  // Compare saturation of colored pixels
  // Return "upright", "flipped", or "uncertain"
}
```

FaB cards have a colored pitch band at the top. If the bottom strip has significantly more color, the card is flipped.

If flipped, the card is rotated 180° in-place.

#### 2.8 Region Extraction

For vertical layouts, extract fixed regions:

- **Title region**: Y 10%, height 4%, X inset 19% each side
- **Art region**: Y 16%, height 42%, X inset 10% each side

For horizontal layouts, regions are computed after 90° CCW rotation (see recognition pipeline).

### 3. Recognition Pipeline (`recognition_pipeline.js`)

The recognition pipeline processes the deskewed card image to compute perceptual hashes.

#### 3.1 Vertical Layout Processing

For vertical cards:

```javascript
// Crop art region
const artImage = cropImageData(deskewedImageData, artRegion)
phashes.push({ kind: "art", value: computePHash(artImage), imageData: artImage })

// Always compute flipped variant (orientation detector isn't 100% reliable)
const flipped = rotated180ImageData(deskewedImageData)
const artFlipped = cropImageData(flipped, artRegion)
phashes.push({ kind: "art_flipped", value: computePHash(artFlipped), imageData: artFlipped })

// Compute full card hash
phashes.push({ kind: "full", value: computePHash(deskewedImageData), imageData: deskewedImageData })
```

**Output hashes:** `art`, `art_flipped`, `full`

#### 3.2 Horizontal Layout Processing

For horizontal cards:

```javascript
// Rotate 90° CCW to portrait orientation
const portrait = rotated90CCWImageData(deskewedImageData)

// Compute art hashes (same as vertical)
const artImage = cropImageData(portrait, artBbox)
phashes.push({ kind: "art", value: computePHash(artImage), imageData: artImage })

const portraitFlipped = rotated180ImageData(portrait)
const artFlippedImage = cropImageData(portraitFlipped, artBbox)
phashes.push({ kind: "art_flipped", value: computePHash(artFlippedImage), imageData: artFlippedImage })

// Split into top/bottom halves for true horizontal cards
const halfH = Math.floor(ph / 2)
const top = cropImageData(portrait, { x: 0, y: 0, width: pw, height: halfH })
const bottom = cropImageData(portrait, { x: 0, y: halfH, width: pw, height: ph - halfH })
phashes.push({ kind: "art_left", value: computePHash(top), imageData: top })
phashes.push({ kind: "art_right", value: computePHash(bottom), imageData: bottom })

// Full card hash (rotated portrait)
phashes.push({ kind: "full", value: computePHash(portrait), imageData: portrait })
```

**Output hashes:** `art`, `art_flipped`, `art_left`, `art_right`, `full`

The rotation serves two purposes:
1. Aligns true horizontal cards (stored portrait in cardvault API)
2. Converts vertical cards laid sideways to upright portrait

### 4. OCR Processing (`preprocessing.js` + `ocr.js`)

#### 4.1 Image Preprocessing

The title region is preprocessed for OCR:

```javascript
// Step 1: Grayscale conversion
gray[i] = 0.299 * r + 0.587 * g + 0.114 * b

// Step 2: Unsharp mask sharpening (amount = 2.0)
sharpened[i] = gray[i] + 2.0 * (gray[i] - blurred)

// Step 3: Nearest-neighbor upscale (3x)
upCtx.imageSmoothingEnabled = false
upCtx.drawImage(grayCanvas, 0, 0, outW, outH)

// Step 4: Adaptive thresholding using integral image
mean = localMeanFromSAT(sat, outW, outH, x, y, blockRadius)
v = upGray[i] < (mean - bias) ? 0 : 255
```

**Output canvases:**
- `rawCanvas` - Original capture
- `grayCanvas` - Grayscale after sharpening
- `sharpThreshCanvas` - Thresholded without upscale
- `upGrayCanvas` - Upscaled grayscale
- `processedCanvas` - Final thresholded result

#### 4.2 OCR Execution

Multiple OCR variants are run in parallel:

```javascript
const [grayResult, upGrayResult, sharpThreshResult, threshResult] = await Promise.all([
  runOCR(cropMargins(grayCanvas)),
  runOCR(cropMargins(upGrayCanvas)),
  runOCR(cropMargins(sharpThreshCanvas)),
  runOCR(cropMargins(processedCanvas)),
])
```

Tesseract.js configuration:
- **Page segmentation mode**: PSM 7 (single text line)
- **Character whitelist**: Alphanumeric, space, apostrophe, hyphen
- **Confidence**: Word-level mean (more reliable than page-level)

The best result (highest confidence) is selected.

#### 4.3 Fallback for Uncertain Orientation

If orientation is "uncertain" and OCR confidence is low (<40), try the flipped title region:

```javascript
if (orientation === "uncertain" && result.confidence < 40) {
  const flippedTitleData = rotated180ImageData(titleImageData)
  const flippedResult = await processAndOCR(flippedTitleData)
  if (flippedResult.confidence > result.confidence) {
    result = flippedResult
  }
}
```

### 5. Pitch Detection (`liveview_hook.js`)

For vertical layouts, detect the pitch color from the top strip:

```javascript
function detectPitchColor(imageData, cardW, cardH) {
  // Sample Y 1-4%, X 25-75%
  // Convert RGB to HSV
  // Vote for red (0-25° or 340-360°), yellow (25-65°), blue (190-260°)
  // Return pitch if >60% votes
}
```

**Returns:** `{ pitch: 1|2|3, confidence: number }` or `null`

- Pitch 1: Red
- Pitch 2: Yellow
- Pitch 3: Blue

### 6. Perceptual Hashing (`p_hash.js`)

The pHash algorithm creates a 64-bit fingerprint for image comparison:

#### 6.1 Algorithm Steps

1. **Resize to 32x32 grayscale**: Area-average downsampling
2. **Compute 2D DCT**: Discrete Cosine Transform
3. **Extract 8x8 low-frequency block**: Top-left corner (excluding DC at [0,0])
4. **Generate hash**: Each bit = 1 if coefficient > median, else 0

#### 6.2 Implementation Details

```javascript
// Precompute cosine table for DCT
const cosTable = new Float64Array(DCT_SIZE * DCT_SIZE)
for (let i = 0; i < DCT_SIZE; i++) {
  for (let j = 0; j < DCT_SIZE; j++) {
    cosTable[i * DCT_SIZE + j] = Math.cos(((2 * j + 1) * i * Math.PI) / (2 * DCT_SIZE))
  }
}

// Row-wise DCT, then column-wise DCT
function dct2d(gray) {
  // ... row DCT ...
  // ... column DCT ...
}

// Extract 8x8 block (63 coefficients, excluding DC)
const coeffs = []
for (let y = 0; y < HASH_SIZE; y++) {
  for (let x = 0; x < HASH_SIZE; x++) {
    if (x === 0 && y === 0) continue
    coeffs.push(dct[y * DCT_SIZE + x])
  }
}

// Build 64-bit hash
let hash = 0n
for (const c of coeffs) {
  hash = (hash << 1n) | (c > median ? 1n : 0n)
}
```

#### 6.3 Hamming Distance

```javascript
export function hammingDistance(a, b) {
  let dist = 0
  let xor = a ^ b
  while (xor !== 0n) {
    xor &= xor - 1n
    dist++
  }
  return dist
}
```

Used to compare hashes: lower distance = more similar images.

### 7. Backend Payload

The final payload sent to the backend via LiveView:

```javascript
const payload = {
  ocr_candidates: [
    { label: "gray", text: result.grayText, confidence: result.grayConfidence },
    { label: "upGray", text: result.upGrayText, confidence: result.upGrayConfidence },
    // ... other variants with confidence > 40 and >= 3 letters
  ],
  phashes: [
    { kind: "art", value: "1234567890..." },
    { kind: "art_flipped", value: "0987654321..." },
    // ... other hashes
  ],
  detected_pitch: 1, // or 2, 3, or omitted
  x: e.clientX - rect.left + 10, // For UI positioning
  y: e.clientY - rect.top - 50,
}
```

**Backend processing:**
- OCR candidates are matched against card titles using fuzzy string matching
- pHashes are compared against stored card hashes using Hamming distance
- Pitch is used as an additional filter
- The backend performs a 4-way LEAST query to find the best match

## Debug Visualization

Enable debug mode by setting `localStorage.setItem("tabletop:card-debug", "true")`.

The debug panel shows:
- Deskewed card capture with layout and angle
- Title region with OCR result
- All pHash regions with their hash values (color-coded by kind)
- Detection signals (layout, orientation, pitch, angle, detection method)

Bounding boxes and card quads are overlaid on the canvas to show what was detected.

## Testing

The recognition pipeline is tested in `recognition.test.mjs`:

```bash
cd tabletop
npm test
```

Tests use fixture images and compare computed hashes against Elixir-stored hashes, asserting Hamming distance is within threshold (15 for art, 8 for full).

Generate fixtures with:
```bash
mix run scripts/snapshot_recognition_fixtures.exs
```

## Limitations

- **Orientation detection**: Only works for vertical cards with colored pitch band
- **OCR**: Requires clear, high-contrast text; struggles with foil cards or poor lighting
- **Card detection**: Requires card to be mostly visible and not overlapping other cards
- **Horizontal cards**: Orientation detection not available; relies on backend's 4-way query
- **Lighting**: Multiple edge detection strategies help, but extreme lighting can fail
