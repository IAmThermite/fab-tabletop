// Frontend recognition test — mirrors the backend recognition_test.exs but
// exercises the JS post-deskew pipeline. For each fixture entry, runs the
// same hashing logic that scan-time uses and asserts the computed hashes
// come within Hamming 15 of the Elixir-stored hashes for the expected
// face_id (the same LEAST < 15 the SQL query enforces).

import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { PNG } from "pngjs"

import { computePhashesForLayout } from "../js/card_scanner/recognition_pipeline.js"
import { hammingDistance } from "../js/card_scanner/p_hash.js"

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURES_DIR = join(__dirname, "..", "..", "test", "fab_tabletop", "cards", "fixtures", "recognition")
const MANIFEST_PATH = join(FIXTURES_DIR, "expected.json")

// Mirror cards.ex per-kind thresholds. `:full` is stricter because whole-card
// hashes share frame/border content across cards.
const ART_THRESHOLD = 15
const FULL_THRESHOLD = 8

function thresholdFor(kind) {
  return kind === "full" ? FULL_THRESHOLD : ART_THRESHOLD
}

function loadManifest() {
  const raw = readFileSync(MANIFEST_PATH, "utf-8")
  const parsed = JSON.parse(raw)
  if (!Array.isArray(parsed)) throw new Error(`Expected array in ${MANIFEST_PATH}, got ${typeof parsed}`)
  return parsed
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
    } else if (kind === "art_left" || kind === "art_right") {
      // 4-way cross-product: client {left, right} × stored {left, right}
      if (stored.image_phash_left != null) {
        recordPairing(kind, "image_phash_left",
          Number(hammingDistance(v, BigInt(stored.image_phash_left))))
      }
      if (stored.image_phash_right != null) {
        recordPairing(kind, "image_phash_right",
          Number(hammingDistance(v, BigInt(stored.image_phash_right))))
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
      layout: entry.expected_orientation,
      // Fixtures are treated as already-deskewed; let the pipeline use its
      // fallback art ratios for vertical cards.
      art: null,
      orientation: "upright",
    })

    if (!entry.stored_phashes) {
      console.warn(
        `  ⚠  ${label}: no stored_phashes in manifest. Run \`mix run scripts/snapshot_recognition_fixtures.exs\` to populate.`,
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
