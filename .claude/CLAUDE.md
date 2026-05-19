# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Flesh and Blood Tabletop — a Phoenix LiveView web app letting two FaB players meet online and play via webcam. The Elixir app lives in [tabletop/](tabletop/); [infrastructure/](infrastructure/) holds the Fly.io Dockerfile and TURN config.

Toolchain pins live in [.tool-versions](.tool-versions): Elixir 1.19.5 / Erlang 28.3.1 / Node 24.11.1. Image processing requires `imagemagick` and OpenCV (via `:evision`) at runtime.

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

- **[Card](tabletop/lib/tabletop/cards/card.ex)** — the *gameplay* entity. Identified by `external_card_id`; carries `name`, `pitch`, and two derived fields `normalized_name` + `tokens` that the `Card.changeset/2` populates via `OcrNormalizer` on every name change. These two are what the OCR fuzzy matcher hits (Postgres `similarity` + token-array overlap + `dmetaphone`).
- **[CardPrint](tabletop/lib/tabletop/cards/card_print.ex)** — a *physical printing/face*. `belongs_to :card`, identified by `face_id` (unique). Holds `set_code`, `art_type`, `orientation`, `layout_position`, `image_url`, the detected `art_bbox`, and up to four pHashes (`image_phash`, `image_phash_left`, `image_phash_right`, `image_phash_full`). Foil/regular pairs collapse to one print (regular preferred) — see importer dedup.

Each card has 1..N prints. `is_canonical` marks one print per card as the display default (regular front face at the standard layout position).

**Lookup rules — keep these straight:**
- **pHash match** (the in-game scanner) queries `card_prints` via `Cards.find_by_p_hash_similarity/1`. Result is up to 5 `%CardPrint{}` rows preloaded with `:card`. The query OR-s across seven arms (art / art_flipped / art_left × image_phash_left|right / art_right × image_phash_left|right / full); horizontal cards get a 4-way left/right cross-check so the player's 180° flip is absorbed without storing a flipped copy.
- **OCR / text match** (fallback) queries `cards` via `Cards.fuzzy_match_name/1` and returns 5 `%Card{}` rows with `card_prints` preloaded *filtered to canonical-only*, so the LiveView can show one image per card without paging through every printing.
- **Pitch variants** — `Cards.find_pitch_variants/2` groups by `normalized_name`, returns one `Card` per distinct pitch, each preloaded with a canonical print biased toward `preferred_set_code`. Use this when surfacing the "this card exists at red/yellow/blue" alternates.
- `Card.canonical_print/2` is the right helper for "pick one print to show" when you already have a card in hand — it requires `card_prints` to be preloaded and returns `nil` otherwise (callers keep their own `card_print` as a fallback).

The importer always inserts the `Card` first, then upserts prints under it keyed by `face_id`; the unique constraints on `cards.external_card_id` and `card_prints.face_id` are what make re-runs idempotent.

### Card recognition pipeline

Happens **in the browser** in a Web Worker, not in Elixir. Pipeline lives in [tabletop/assets/js/card_scanner/](tabletop/assets/js/card_scanner/) and is bundled by the `scanner_worker` esbuild target:

1. OpenCV (in-browser) finds the card bounding box; predetermined offsets locate art and title regions.
2. A 64-bit pHash of the art is computed ([p_hash.js](tabletop/assets/js/card_scanner/p_hash.js)); tesseract.js OCR runs on the title ([ocr.js](tabletop/assets/js/card_scanner/ocr.js)).
3. The hash + OCR text are sent to the LiveView, which matches against `card_prints` (pHash, with per-kind Hamming thresholds — see comments in [Tabletop.Cards](tabletop/lib/tabletop/cards.ex)) and falls back to fuzzy text match on `cards` using Postgres `similarity` + `dmetaphone`.

The Elixir-side server-only equivalents — [Tabletop.Cards.ArtBboxDetector](tabletop/lib/tabletop/cards/art_bbox_detector.ex), [PHash](tabletop/lib/tabletop/cards/p_hash.ex), [OcrNormalizer](tabletop/lib/tabletop/cards/ocr_normalizer.ex) — are used by the importer below when ingesting card data.

### Card importer

[Tabletop.Cards.Importer](tabletop/lib/tabletop/cards/importer.ex) pulls the card database from cardvault (fabtcg). It's a deliberate **three-stage offline pipeline**, not a live sync — runs ad hoc from `iex` (see [scripts/smoke_importer.exs](tabletop/scripts/smoke_importer.exs) for a sample invocation):

1. **`fetch_raw_card_list/2`** — pages the cardvault advanced-search endpoint into `priv/cards/raw/api.cardvault.fabtcg.com-<n>.json` (clears the dir first).
2. **`import_and_generate/1`** — for each raw page, fetches per-card detail, picks one face per `(set_code, art_type, layout_position)` (regular finish preferred over foil), detects the art bbox with OpenCV, computes pHashes (full-art + per-half for double-face/oriented layouts), and writes a snapshot to `priv/cards/generated/cards-<n>.json`. Two `Task.async_stream` stages (`@fetch_concurrency` 10, `@phash_concurrency` 15) gate concurrency. If `insert: true` (default) it also writes rows immediately.
3. **`import_from_generated_data/0`** — replays the JSON snapshots into Postgres. **Idempotent**: skips cards whose `external_card_id` is already present and prints by `face_id`. This is the path to use when re-hydrating a fresh DB without re-downloading every image.

Two non-obvious bits worth knowing before changing it:
- The snapshot JSON is decoded with `Jason.decode(..., keys: :atoms!)`, which only converts to *already-loaded* atoms. Every key referenced is intentionally present in `Card`, `CardPrint`, or `ArtBboxDetector` so they're loaded at compile time — adding a new field requires referencing the atom somewhere in those modules first, or the importer will crash on existing snapshots.
- pHash shape varies by face: a normal face gets `image_phash` + `image_phash_full`; a face whose bbox detector returns `halves: [left, right | _]` gets `image_phash_left` + `image_phash_right` + `image_phash_full` (no single `image_phash`). The Hamming-distance match in [Tabletop.Cards](tabletop/lib/tabletop/cards.ex) expects to OR across these arms — keep that contract if you add new hash kinds.

### Routing & auth

[tabletop_web/router.ex](tabletop/lib/tabletop_web/router.ex) — three `live_session` scopes: anonymous-friendly (`/`, `/games/:id`, `/camera-setup`), authenticated (`/users/settings`), and sudo-mode (password confirm). `/phone-camera/:token` is in its own session — used by the phone when scanning the QR code from desktop. `/dev/dashboard` and `/dev/mailbox` exist only when `:dev_routes` is set.

## Conventions worth knowing

- The Elixir app is a sub-directory (`tabletop/`), not the repo root. Run `mix` from there.
- Don't move ephemeral game state into Ecto — sessions are intentionally in-memory; persistence is limited to `Game` metadata.
- When adding a new `GameSession` action, both `dispatch/2` (in `game_session.ex`) and the corresponding `GameState` transform must be added; broadcasts go out automatically via `broadcast_update/4`.
- Don't add any Elixir `@spec` documentation, but be sure to document other functions where necessary.
