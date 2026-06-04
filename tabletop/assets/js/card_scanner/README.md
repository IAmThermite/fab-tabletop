# Frontend Card Recognition Pipeline

This document outlines the end-to-end flow of the frontend card recognition system, from user interaction to backend payload generation.

## Overview

The card recognition system uses OpenCV (in a Web Worker) to detect + deskew the card and perceptual hashing (pHash) for image-based identification. Horizontal (landscape) captures are rotated to portrait inside the OpenCV worker, so everything downstream treats every card as vertical — a single path with automatic orientation detection.

Recognition is **pHash-only**. There is no OCR. If a card is detected but the server finds no pHash match, the scanner retries a few times — each attempt grows the deskewed capture region by a configurable step (`REGION_EXPAND_STEP`, default 5%, up to `MAX_MATCH_RETRIES` extra tries) so a sleeve or border that threw off the detected edges is less likely to matter. If it still misses, nothing opens and the player can type the name into the search box instead (handled server-side by `Cards.fuzzy_match_name/1`, independent of this pipeline).

## Architecture

```
User Click → LiveView Hook → OpenCV Worker → Recognition Pipeline → Backend Payload
                      ↓              ↓                ↓
                   Capture Region   Deskew         pHash (art / art_flipped / full)
                      ↓              ↓                ↓
                   Detect Card    Orientation     Pitch Detection
```

## Module Overview

- **`liveview_hook.js`** - Main entry point, coordinates the pipeline and handles user interaction
- **`scanner_worker.js`** - OpenCV web worker for card detection and deskewing
- **`recognition_pipeline.js`** - Post-deskew processing and perceptual hashing
- **`preprocessing.js`** - `imageDataToCanvas` helper (bridges the pipeline's duck-typed ImageData to real canvases for the debug panel)
- **`p_hash.js`** - DCT-based 64-bit perceptual hashing algorithm
- **`debug.js`** - Debug visualization panel

## End-to-End Flow

### 1. User Interaction (`liveview_hook.js`)

When a user clicks on the game area canvas:

```javascript
gameArea.addEventListener("click", async (e) => {
  showLoading(e.clientX, e.clientY)

  // Detect + deskew the card and compute its pHashes
  const result = await captureAndDetect(canvasEl, e.clientX, e.clientY, isFlipped(), gameArea)

  // Send hashes to the backend for a pHash match
  if (result?.phashes?.length) {
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

A horizontal capture is immediately rotated **90° CCW into portrait** (matching how the cardvault API stores landscape cards) and the layout is treated as `vertical` from that point on. The original layout is preserved as `originalLayout` for the debug panel. This unifies both true landscape cards and vertical cards laid sideways into one path.

#### 2.7 Orientation Detection

After any horizontal→portrait rotation, detect if the (now portrait) card is upside-down by comparing color saturation:

```javascript
function detectOrientation(cardData, cardW, cardH) {
  // Sample top 1-4% and bottom 96-99% strips
  // Compare saturation of colored pixels
  // Return "upright", "flipped", or "uncertain"
}
```

FaB cards have a colored pitch band at the top. If the bottom strip has significantly more color, the card is flipped. If flipped, the card is rotated 180° in-place. True landscape cards have no top-edge pitch strip, so they return `"uncertain"`; the `art`/`art_flipped` pHash pair absorbs that ambiguity.

#### 2.8 Region Extraction

The art region is extracted from the (now always portrait) card:

- **Art region**: Y 16%, height 42%, X inset 10% each side

### 3. Recognition Pipeline (`recognition_pipeline.js`)

The recognition pipeline processes the (always portrait) deskewed card image to compute perceptual hashes. Because the worker has already rotated horizontal captures, there is a single code path:

```javascript
// Crop art region
const artImage = cropImageData(deskewedImageData, artRegion)
phashes.push({ kind: "art", value: computePHash(artImage), imageData: artImage })

// Always compute flipped variant (orientation detector isn't 100% reliable,
// and this absorbs the 180° ambiguity of cards laid either way up)
const flipped = rotated180ImageData(deskewedImageData)
const artFlipped = cropImageData(flipped, artRegion)
phashes.push({ kind: "art_flipped", value: computePHash(artFlipped), imageData: artFlipped })

// Compute full card hash
phashes.push({ kind: "full", value: computePHash(deskewedImageData), imageData: deskewedImageData })
```

**Output hashes:** `art`, `art_flipped`, `full`

The backend matches `art` and `art_flipped` against the stored `image_phash` and `full` against `image_phash_full`. There is no separate left/right-half handling — landscape cards are matched the same way as portrait cards after the worker's rotation.

### 4. Pitch Detection (`liveview_hook.js`)

Detect the pitch color from the top strip of the deskewed card:

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

### 5. Perceptual Hashing (`p_hash.js`)

The pHash algorithm creates a 64-bit fingerprint for image comparison:

#### 5.1 Algorithm Steps

1. **Resize to 32x32 grayscale**: Area-average downsampling
2. **Compute 2D DCT**: Discrete Cosine Transform
3. **Extract 8x8 low-frequency block**: Top-left corner (excluding DC at [0,0])
4. **Generate hash**: Each bit = 1 if coefficient > median, else 0

#### 5.2 Hamming Distance

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

### 6. Backend Payload

The final payload sent to the backend via LiveView:

```javascript
const payload = {
  phashes: [
    { kind: "art", value: "1234567890..." },
    { kind: "art_flipped", value: "0987654321..." },
    { kind: "full", value: "..." },
  ],
  detected_pitch: 1, // or 2, 3, or omitted
  x: e.clientX - rect.left + 10, // For UI positioning
  y: e.clientY - rect.top - 50,
}
```

**Backend processing:**
- pHashes are compared against stored card hashes using Hamming distance
- The backend ranks candidates with a `LEAST` query over the `art`, `art_flipped`, and `full` arms
- Pitch is used to pick the default pitch variant of the matched card
- `open_card` always replies `{matched: boolean}` so the client knows whether to retry with a larger capture region (see Overview)

## Debug Visualization

Enable debug mode by setting `localStorage.setItem("tabletop:card-debug", "true")`.

The debug panel shows:
- Deskewed card capture with layout and angle
- All pHash regions with their hash values (color-coded by kind)
- Detection signals (layout, orientation, pitch, angle)

Bounding boxes and card quads are overlaid on the canvas to show what was detected.

## Testing

The recognition pipeline is tested in `recognition.test.mjs`:

```bash
cd tabletop
mix test.assets
```

Tests use fixture images and compare computed hashes against Elixir-stored hashes, asserting Hamming distance is within threshold (15 for art, 8 for full).

## Limitations

- **Orientation detection**: Relies on the colored pitch band; true landscape cards have none, so they return `"uncertain"` and lean on the `art`/`art_flipped` pair
- **Card detection**: Requires card to be mostly visible and not overlapping other cards
- **Lighting**: Multiple edge detection strategies help, but extreme lighting can fail
- **No OCR**: cards that pHash can't match must be found via the manual name-search box
