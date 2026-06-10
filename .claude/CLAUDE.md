# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Flesh and Blood Tabletop — a Phoenix LiveView web app letting two FaB players meet online and play via webcam. The Elixir app lives in [tabletop/](tabletop/); [infrastructure/](infrastructure/) holds the Fly.io Dockerfile and TURN config.

Toolchain pins live in [.tool-versions](.tool-versions): Elixir 1.19.5 / Erlang 28.3.1 / Node 24.11.1. There is no server-side image processing: card pHashes are imported precomputed (see Card importer) and the scanner's OpenCV runs in-browser (`opencv.js`), so no `imagemagick`/`:evision` is needed at runtime.

## Commands

All `mix` commands run from [tabletop/](tabletop/).

**Setup:** `docker compose up -d database` (Postgres on host port 5555), then `mix setup` (deps, ecto.setup, asset install + build).

**Dev server:** `mix phx.server` — HTTP on `:4000`, HTTPS on `:4001` (self-signed cert at `priv/cert/`; generate via `mix phx.gen.cert` if missing). HTTPS is needed for getUserMedia (webcam).

**Tests:**
- `mix test` — runs Ecto create/migrate then the suite. The pool is sandboxed.
- `mix test path/to/file_test.exs:LINE` — single test.
- `mix test.assets` — Node tests for the in-browser card recognition pipeline ([tabletop/assets/test/](tabletop/assets/test/), via `node --test`).

**Lint / pre-commit:** `mix precommit` runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`. CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs `mix format --check-formatted` and `mix deps.unlock --check-unused` separately — keep both clean.

**Assets:** `mix assets.build` bundles Tailwind, the main `tabletop` esbuild target, and the `scanner_worker` target (Web Worker). Dev watchers run automatically under `mix phx.server`.

## Architecture

The app has two cooperating real-time layers on top of the standard Phoenix/Ecto stack — get both straight before changing game flow.

### Layer 1 — Authoritative game state (LiveView + GenServer + PubSub)

Per active game, a single [Tabletop.Games.GameSession](tabletop/lib/tabletop/games/game_session.ex) GenServer holds both players' transient `Tabletop.Fab.GameState` (life, damage, combat-chain tiles, effects, proxy tokens). It is registered via `{:via, Registry, {GameSessionRegistry, game_id}}` and supervised by `GameSessionSupervisor` (see [application.ex](tabletop/lib/tabletop/application.ex)).

- LiveViews call `GameSession.apply_action(game_id, actor_user_id, action)`; the server resolves which side the action targets, applies a `GameState` transform, and broadcasts `{:game_update, side, delta, actor_user_id}` on `game_session:<game_id>`.
- State is ephemeral — on crash the supervisor restarts with defaults and broadcasts `{:session_reset, snapshot}` so connected clients clear stale assigns.
- Persistent metadata (the `Game` row, players, ownership) lives in Postgres via [Tabletop.Games](tabletop/lib/tabletop/games.ex).

### Layer 2 — Webcam transport (WebRTC + Phoenix Channels)

`UserSocket` ([channels/user_socket.ex](tabletop/lib/tabletop_web/channels/user_socket.ex)) accepts two token kinds — `token` (24 h, normal user) and `camera_relay_token` (1 h, the phone-as-camera flow).

- **`game:*`** — `GameChannel` brokers WebRTC SDP/ICE between the two players in a game.
- **`camera_relay:*`** — `CameraRelayChannel` relays WebRTC signalling between a player's desktop and their *own* phone (used when they want the phone to act as the webcam). The topic is keyed by **stable user_id**, not the rotating relay token, because the token regenerates each LiveView mount and the two peers would otherwise land in different topics. Channel-to-channel fanout uses Erlang `:pg` (group `:game_channels`), set up in `application.ex`.

### Disconnect / leave timer

[Tabletop.Games.LeaveTimer](tabletop/lib/tabletop/games/leave_timer.ex) gives a disconnecting user a 5-minute grace period before being marked left. The non-obvious bit: on page refresh the reconnecting LiveView's `mount/3` can run *before* the previous LiveView's `terminate/2`, so timers also consult a duplicate-key `GameConnectionRegistry` (every connected LiveView calls `track_connection/2`) — schedule/fire is skipped while any live connection for the user exists.

### Card / CardPrint schema split

The cards data model is intentionally split into two tables — match the right one to the right job or queries get awkward. Flesh and Blood cards have multiple prints for one card, as denoted by their `set_code` and `print`. We split these out based on the rules in [Tabletop.Cards.Importer](tabletop/lib/tabletop/cards/importer.ex).

- **[Card](tabletop/lib/tabletop/cards/card.ex)** — the *gameplay* entity. Identified by `external_card_id`; carries `name`, `pitch`, and two derived fields `normalized_name` + `tokens` that the `Card.changeset/2` populates via `OcrNormalizer` on every name change. These two back the **manual name-search** matcher (Postgres `similarity` + token-array overlap + `dmetaphone`); `normalized_name` is also the pitch-variant grouping key. (Webcam OCR was removed — scanning is pHash-only.)
- **[CardPrint](tabletop/lib/tabletop/cards/card_print.ex)** — a *physical printing/face*. `belongs_to :card`, identified by `face_id` (unique). Holds `set_code`, `art_type`, `orientation`, `image_url`, and two pHashes (`image_phash` for the art crop, `image_phash_full` for the whole card). Foil/regular pairs collapse to one print (regular preferred) — see importer dedup.

Each card has 1..N prints. `is_canonical` marks one print per card as the display default (regular front face at the standard layout position).

**Lookup rules — keep these straight:**
- **pHash match** (the in-game scanner) queries `card_prints` via `Cards.find_by_p_hash_similarity/1`. Result is up to 5 `%CardPrint{}` rows preloaded with `:card`. The query OR-s across three arms (`art` and `art_flipped` vs `image_phash`, `full` vs `image_phash_full`) with per-kind Hamming thresholds. Horizontal cards are rotated to portrait by the scanner and matched exactly like vertical cards; the `art`/`art_flipped` pair absorbs the player's 180° flip without storing a flipped copy.
- **Name search** (the manual `search_card` box, *not* OCR) queries `cards` via `Cards.fuzzy_match_name/1` and returns 5 `%Card{}` rows with `card_prints` preloaded *filtered to canonical-only*, so the LiveView can show one image per card without paging through every printing.
- **Pitch variants** — `Cards.find_pitch_variants/2` groups by `normalized_name`, returns one `Card` per distinct pitch, each preloaded with a canonical print biased toward `preferred_set_code`. Use this when surfacing the "this card exists at red/yellow/blue" alternates.
- `Card.canonical_print/2` is the right helper for "pick one print to show" when you already have a card in hand — it requires `card_prints` to be preloaded and returns `nil` otherwise (callers keep their own `card_print` as a fallback).

The importer always inserts the `Card` first, then upserts prints under it keyed by `face_id`; the unique constraints on `cards.external_card_id` and `card_prints.face_id` are what make re-runs idempotent.

### Card recognition pipeline

Happens **in the browser** in a Web Worker, not in Elixir. Pipeline lives in [tabletop/assets/js/card_scanner/](tabletop/assets/js/card_scanner/) and is bundled by the `scanner_worker` esbuild target:

1. OpenCV (in-browser) finds the card bounding box and deskews it; a horizontal capture is rotated to portrait so everything downstream is treated as vertical. Predetermined offsets locate the art region.
2. A 64-bit pHash of the art (and its 180°-flipped variant) plus a whole-card pHash are computed ([p_hash.js](tabletop/assets/js/card_scanner/p_hash.js)). There is no OCR — recognition is pHash-only.
3. The hashes are sent to the LiveView, which matches against `card_prints` (pHash, with per-kind Hamming thresholds — see comments in [Tabletop.Cards](tabletop/lib/tabletop/cards.ex)). `open_card` replies `{matched: boolean}`; on a miss the client retries a few times, each time growing the deskewed capture region (`REGION_EXPAND_STEP`) so sleeves/borders matter less. If it still misses, nothing opens; the player can type the name into the search box, which fuzzy-matches `cards` via `similarity` + `dmetaphone`.

The Elixir-side server equivalents — [PHash](tabletop/lib/tabletop/cards/p_hash.ex) (the reference hash implementation; now used only by tests and `hamming_distance/2` for the live match display, since import hashes are precomputed) and [OcrNormalizer](tabletop/lib/tabletop/cards/ocr_normalizer.ex) (name normalization for search, despite the legacy name) — back the match/search paths. The importer below ingests precomputed pHashes, so it no longer crops or hashes images.

### Card importer

[Tabletop.Cards.Importer](tabletop/lib/tabletop/cards/importer.ex) loads the card database from the **flesh-and-blood-cards** data set, vendored as a git submodule at `vendor/flesh-and-blood-cards` (tracking branch `feature/card-art-hashes`; switch to `main` once merged). That repo ships **precomputed pHashes** (`phash_art`, `phash_full`) generated with an algorithm byte-for-byte identical to ours, so the importer does **no image downloading or hashing** — it reads `json/english/card.json`, transforms each card + printings, and inserts directly. Runs ad hoc from `iex` (`Tabletop.Cards.Importer.import_all()`); see [scripts/smoke_importer.exs](tabletop/scripts/smoke_importer.exs) for a fixture-driven sample.

- **`import_all/1`** — reads the source JSON (decoded with plain string keys, *not* `:atoms!`), transforms, inserts. **Idempotent** on `cards.external_card_id` and `card_prints.face_id`.
- **Source path** resolves via `source_path/0`: a release bundles the file into `priv/cards/card.json` (copied from the submodule by the [Dockerfile](infrastructure/Dockerfile)); dev falls back to the submodule working tree. Override with the `:card_source_path` app env or `import_all(source: ...)`.

Mapping rules worth knowing before changing it:
- **`face_id` ← printing `unique_id`** (globally unique). The shorter `id` (e.g. `"MST131"`) is *not* image-unique across editions/foilings — don't key on it.
- **Foiling dedup is by image identity**: printings sharing a `phash_full` collapse to one print (standard `"S"` preferred); a cold-foil print whose image genuinely differs survives as its own print. Exactly one print per card is marked `is_canonical` (regular art, standard foiling, earliest in source order).
- **`art_type`**: `[] → "regular"`, contains `"FA" → "full_art"`, else `"alternate"`. Only drives display + canonical selection — full-art prints still match because the source hashes them on the same regular art rect the scanner uses.
- **Drop rules**: imageless printings are dropped (changeset requires `image_url`); a card with no imaged prints is skipped; horizontal prints have no `phash_art` so `image_phash` is `nil` (full arm still matches). `image_phash` (art) + `image_phash_full` (whole card) remain the two match arms in [Tabletop.Cards](tabletop/lib/tabletop/cards.ex) — keep that contract.
- **Bump card data**: `git submodule update --remote vendor/flesh-and-blood-cards`, commit the moved gitlink, then re-run `import_all/1`. CI/deploy must `git submodule update --init` before the Docker build.

### Routing & auth

[tabletop_web/router.ex](tabletop/lib/tabletop_web/router.ex) — three `live_session` scopes: anonymous-friendly (`/`, `/games/:id`, `/camera-setup`), authenticated (`/users/settings`), and sudo-mode (password confirm). `/phone-camera/:token` is in its own session — used by the phone when scanning the QR code from desktop. `/dev/dashboard` and `/dev/mailbox` exist only when `:dev_routes` is set.

## Conventions worth knowing

- The Elixir app is a sub-directory (`tabletop/`), not the repo root. Run `mix` from there.
- Don't move ephemeral game state into Ecto — sessions are intentionally in-memory; persistence is limited to `Game` metadata.
- When adding a new `GameSession` action, both `dispatch/2` (in `game_session.ex`) and the corresponding `GameState` transform must be added; broadcasts go out automatically via `broadcast_update/4`.
- Don't add any Elixir `@spec` documentation, but be sure to document other functions where necessary.

# Important instructions

- If you discover a pre existing issue to anything, please fix it and make note of it, do not ignore and pass it off as a comment.
