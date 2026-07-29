// Frontend recognition test — exercises the JS post-deskew pipeline. For each
// fixture entry, runs the same hashing logic that scan-time uses and asserts
// the computed hashes land inside the per-kind Hamming thresholds against the
// Elixir-stored hashes for the expected face_id (the same LEAST < threshold
// the SQL query enforces).
//
// Fixtures come from the app itself: enable "Card scan debug overlay" in the
// in-game settings dialog, scan a card, and click "Save scan capture" at the
// bottom of the popout's debug block — the browser downloads a `<name>.png` +
// `<name>.json` pair. Drop both into
// `test/tabletop/cards/fixtures/recognition/` and they run from the next
// `mix test.assets`.

import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync, existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { PNG } from "pngjs"

import { computePhashesForLayout } from "../js/card_scanner/recognition_pipeline.js"
import { hammingDistance } from "../js/card_scanner/p_hash.js"

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURES_DIR = join(__dirname, "..", "..", "test", "tabletop", "cards", "fixtures", "recognition")

// Mirror cards.ex per-kind thresholds. `:full` is stricter because whole-card
// hashes share frame/border content across cards.
const ART_THRESHOLD = 15
const FULL_THRESHOLD = 8

function thresholdFor(kind) {
  return kind === "full" ? FULL_THRESHOLD : ART_THRESHOLD
}

// Every `*.json` in the fixtures directory contributes entries — either one
// entry object or an array of them. That is what makes the in-app "Save scan
// capture" button a one-step workflow: it downloads `<name>.png` +
// `<name>.json`, you drop both in here, and the fixture is live with no
// manifest to hand-edit.
//
// Fixtures are opt-in; with the directory absent the whole file is a no-op
// (matches the empty-array branch below).
function loadManifest() {
  if (!existsSync(FIXTURES_DIR)) return []

  const entries = []
  for (const file of readdirSync(FIXTURES_DIR).sort()) {
    if (!file.endsWith(".json")) continue

    const parsed = JSON.parse(readFileSync(join(FIXTURES_DIR, file), "utf-8"))
    for (const entry of Array.isArray(parsed) ? parsed : [parsed]) {
      if (!entry || typeof entry !== "object" || typeof entry.image !== "string") {
        throw new Error(`${file}: every fixture entry needs a string "image" field`)
      }
      entries.push({ ...entry, sourceFile: file })
    }
  }
  return entries
}

function loadImageData(imagePath) {
  const buffer = readFileSync(imagePath)
  const png = PNG.sync.read(buffer)
  // pngjs returns Buffer; ImageData duck-type wants Uint8ClampedArray.
  return {
    data: new Uint8ClampedArray(png.data.buffer, png.data.byteOffset, png.data.byteLength),
    width: png.width,
    height: png.height,
  }
}

// Mirror Cards.find_by_p_hash_similarity/2: a row qualifies if any arm is
// below its kind's threshold. Returns `{winner, all}` where `winner` is the
// closest qualifying pairing (or null) and `all` is every checked pairing.
function leastDistance(computed, stored) {
  const all = []

  const recordPairing = (kind, against, distance) => {
    const threshold = thresholdFor(kind)
    all.push({ kind, against, distance, threshold, qualifies: distance < threshold })
  }

  for (const { kind, value } of computed) {
    const v = BigInt(value)

    if (kind === "art" || kind === "art_flipped") {
      if (stored.image_phash != null) {
        recordPairing(kind, "image_phash",
          Number(hammingDistance(v, BigInt(stored.image_phash))))
      }
    } else if (kind === "full") {
      if (stored.image_phash_full != null) {
        recordPairing(kind, "image_phash_full",
          Number(hammingDistance(v, BigInt(stored.image_phash_full))))
      }
    }
  }

  const qualifying = all.filter(p => p.qualifies)
  const winner = qualifying.length === 0
    ? null
    : qualifying.reduce((a, b) => (b.distance < a.distance ? b : a))

  return { winner, all }
}

const manifest = loadManifest()

if (manifest.length === 0) {
  test("recognition fixtures (manifest empty)", () => {
    // No-op: same opt-in shape as the backend test.
  })
}

for (const entry of manifest) {
  const label = entry.scenario || entry.image
  const imagePath = join(FIXTURES_DIR, entry.image)

  test(`recognition: ${label}`, () => {
    const image = loadImageData(imagePath)

    const computed = computePhashesForLayout(image, {
      // What the pipeline branches on. Horizontal captures are rotated to
      // portrait by the worker, so every saved capture is "vertical".
      layout: entry.layout || "vertical",
      // Fixtures are already deskewed. A capture exported from the app carries
      // the exact art rect it hashed; without one, fall back to the pipeline's
      // ratios.
      art: entry.art || null,
      // Ignored by the pipeline (it always hashes both orientations) and the
      // capture is already de-rotated — passed for documentation only.
      orientation: "upright",
    })

    // The saved PNG must be a byte-faithful copy of the pixels the browser
    // hashed at scan time, otherwise the fixture proves nothing about the
    // live scanner. PNG is lossless, so these are expected to be identical.
    if (entry.computed_phashes) {
      for (const { kind, value } of computed) {
        const captured = entry.computed_phashes[kind]
        if (captured == null) continue
        assert.equal(
          value.toString(),
          String(captured),
          `${label}: replayed ${kind} hash ${value} != the ${captured} computed in-browser at ` +
          `capture time — the fixture image is not the pixels that were scanned`,
        )
      }
    }

    if (!entry.stored_phashes) {
      console.warn(
        `  ⚠  ${label}: no stored_phashes in ${entry.sourceFile}. Re-export it with the ` +
        `popout's "Save scan capture" button so the matched print's hashes are recorded.`,
      )
      // Print computed values to help the user verify.
      for (const { kind, value } of computed) {
        console.warn(`     phash:${kind} = ${value}`)
      }
      return
    }

    const { winner, all } = leastDistance(computed, entry.stored_phashes)

    const breakdown = all
      .map(p => `${p.kind}↔${p.against}=${p.distance} (<${p.threshold} ${p.qualifies ? "✓" : "✗"})`)
      .join(", ")

    assert.ok(
      winner != null,
      `${label}: no pairing passed its threshold (expected face_id ${entry.expected_face_id}). ` +
      `Per-pairing: ${breakdown}`,
    )

    console.log(`  ✓ ${label}: matched via ${winner.kind}↔${winner.against} at distance ${winner.distance} (<${winner.threshold})`)
  })
}
