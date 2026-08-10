# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Flesh and Blood Tabletop — a Phoenix LiveView web app letting two FaB players meet online and play via webcam. The Elixir app lives in [tabletop/](tabletop/); [infrastructure/](infrastructure/) holds the Fly.io Dockerfile and TURN config.

Toolchain pins live in [.tool-versions](.tool-versions): Elixir 1.19.5 / Erlang 28.3.1 / Node 24.11.1. There is no server-side image processing: card pHashes are imported precomputed (see Card importer) and the scanner's OpenCV runs in-browser (`opencv.js`), so no `imagemagick`/`:evision` is needed at runtime.

## Commands

All `mix` commands run from [tabletop/](tabletop/).

**Setup:** `docker compose up -d database` (Postgres on host port 5432), then `mix setup` (deps, ecto.setup, asset install + build).

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

**The relay id must be identical in the dead and connected renders.** The phone's half of the topic comes from the QR code, which lives inside the `phx-update="ignore"` settings dialog — so the QR the user actually scans is the one from the **dead** render, frozen for the page's lifetime. The desktop's half comes from `data-relay-user-id`, which the JS hook reads after the **connected** render. Anything minted per-`mount/3` therefore desyncs the two, and the phone sits on "Waiting for desktop..." in a topic nobody else joined. That is why anonymous ids come from the session ([TabletopWeb.Plugs.AnonymousId](tabletop/lib/tabletop_web/plugs/anonymous_id.ex), in the `:browser` pipeline) rather than from `mount/3`, and why [CameraRelayToken](tabletop/lib/tabletop_web/camera_relay_token.ex)'s `max_age` is 24 h — the frozen QR can't be refreshed, so a short token would silently rot on a long game.

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

### Tournaments

Swiss-into-top-cut tournament running on top of the normal game stack. The data model lives under [Tabletop.Tournaments](tabletop/lib/tabletop/tournaments/) (all UUID PKs, one migration: [20260423000001_create_tournaments.exs](tabletop/priv/repo/migrations/20260423000001_create_tournaments.exs)); the [Tabletop.Tournaments](tabletop/lib/tabletop/tournaments.ex) context is the only public entry point. Keep the two layers separate — see below.

**Pairing engine — pure, no Ecto.** Everything under [Tabletop.Tournaments.Pairing](tabletop/lib/tabletop/tournaments/pairing/) is a side-effect-free library that operates on plain structs ([Player](tabletop/lib/tabletop/tournaments/pairing/player.ex), [Match](tabletop/lib/tabletop/tournaments/pairing/match.ex)), never DB rows. The context translates rows ↔ structs via `to_pairing_players/2` (folds confirmed matches into per-player `Player` stats) and back. Don't reach into Ecto from these modules, and don't duplicate scoring logic in the context — call the engine.
- **[Swiss.pair/3](tabletop/lib/tabletop/tournaments/pairing/swiss.ex)** — one round of Swiss. Score-bracketed top-half-vs-bottom-half with DFS backtracking for rematch avoidance; odd buckets float their lowest player down; an odd overall field gives the lowest player without a bye a bye. Tie-break shuffle is seeded (`rng_seed`, defaults to `{round, count}`) so pairings are **deterministic** — tests rely on this.
- **[Bracket](tabletop/lib/tabletop/tournaments/pairing/bracket.ex)** — single-elim seeding/advancement. `seed/1` requires a power-of-two field (`@valid_sizes [4, 8, 16]`, matching the non-zero `@cut_sizes`); `advance/1` returns `{:next, pairings}` or `{:done, champion}`.
- **[Standings.compute/2](tabletop/lib/tabletop/tournaments/pairing/standings.ex)** — FAB tiebreakers in order: match points → OMW% → GW% → OGW%, each opponent-% floored at 0.3333, byes excluded from opponent denominators.
- **[Scoring](tabletop/lib/tabletop/tournaments/pairing/scoring.ex)** — points config; default win 3 / draw 1 / loss 0 / bye 3.

**Lifecycle & status.** `Tournament.status` runs `:draft → :registration → :check_in → :swiss → :cut → :finished` (plus `:cancelled`), driven only by admin actions on the context: `open_registration` → `open_check_in` (closes sign-ups — `register/3` only accepts `:registration` — stamps `check_in_opened_at`, clears all `checked_in_at`) → `start_tournament` (requires `:check_in`; gated on both `check_in_min_elapsed?/1` — the `check_in_min_seconds/0` minimum since check-in opened — and `start_time_reached?/1` — the scheduled `starts_at`, if set, must have passed, else `{:error, :before_start_time}`; **drops every registration without a `checked_in_at`**, then seeds the rest by join order and generates Swiss round 1) → `generate_next_swiss_round` (repeats until `swiss_rounds` reached) → `generate_top_cut` (takes top `top_cut_size` by standings; `0` cut finishes straight from standings) → `advance_bracket` (loops cut rounds until a champion). Each generator sets `tournament.current_round_id`. A round can only advance once `round_fully_confirmed?` — every match has a `confirmed_result`. During check-in, players call `check_in/2` to mark `registration.checked_in_at`; `check_in_min_seconds` defaults to 300 and is overridable via the `:check_in_min_seconds` app env (the test suite sets `0`).

**Result reporting → confirmation.** Players call `report_result/3` (`player1_reported`/`player2_reported`, one of `p1_win|p2_win|draw`); admin `confirm_match/2` only succeeds when both players' reports agree, else `override_match/3` sets the result directly. Confirming a match runs `maybe_complete_round` (stamps `completed_at` when no unconfirmed matches remain). Byes are inserted pre-confirmed (`confirmed_result: "bye"`). `confirmed_result` widens to `double_loss`/`bye` beyond the reportable set — see `@reported_values` vs `@confirmed_values` in [TournamentMatch](tabletop/lib/tabletop/tournaments/tournament_match.ex).

**Bridge to the game stack.** Every non-bye pairing inserts a real `Tabletop.Games.Game` row (`create_match_game!`, status `:active`, the two players as `user_id`/`user2_id`) and links it via `match.game_id`. So a tournament match *is* an ordinary webcam game — players join through the normal game UI; the result loops back via `report_result`. Use `get_match_by_game_id/1` to go from a game back to its match.

**Admin & auth.** Admin-only context actions guard with `ensure_admin!` → raises [NotAdminError](tabletop/lib/tabletop/not_admin_error.ex) (app-level, shared with `Tabletop.Announcements` — admin is one privilege, not a per-context one); admin is membership in the `:admin_ids` app-env list (`Scope.admin?/1`). Web layer: [TournamentLive](tabletop/lib/tabletop_web/live/tournament_live/) — `Index`/`Show` are anonymous-friendly, `Form`/`Admin` sit in the `:admin` `live_session`. Registration requires a Fabrary decklist URL (regex-validated in [TournamentRegistration](tabletop/lib/tabletop/tournaments/tournament_registration.ex)).

**PubSub.** Three topics: `"tournaments"` (`{:tournaments_updated}`, list-level) and `"tournament:<id>"` (`{:tournament_updated, id}`, anything attached to one tournament) — context writers broadcast, LiveViews subscribe and reload — plus per-player `"user_notifications:<user_id>"` (`{:user_notification, payload}`). The context fires the latter on player-facing events (check-in opens, a new round/match is generated, the tournament finishes) via `notify_*` helpers. [TabletopWeb.UserNotifications](tabletop/lib/tabletop_web/live/user_notifications.ex) is the single subscriber — an `on_mount` hook wired into the `:current_user`/authenticated `live_session`s that turns each notification into a flash **toast** and refreshes the `@notification_items` **banner** list (`Tournaments.player_action_items/1`, data-derived: outstanding check-ins + ready matches, rendered by `<.notification_banners>` on the home + tournaments-list pages). Pages must read `@notification_items` rather than subscribing again (double-delivery).

### Routing & auth

[tabletop_web/router.ex](tabletop/lib/tabletop_web/router.ex) — four `live_session` scopes: anonymous-friendly (`/`, `/games/:id`, `/camera-setup`), authenticated (`/users/settings`), sudo-mode (password confirm), and `:admin` (tournament management + `/admin/announcements`, gated on `Scope.admin?/1`). `/phone-camera/:token` is in its own session — used by the phone when scanning the QR code from desktop. `/dev/mailbox` exists only when `:dev_routes` is set.

**LiveDashboard.** `/dev/dashboard` is mounted in *every* environment, but its guard is picked at compile time. With `:dev_routes` set it is wide open; otherwise the route carries both a pipeline (`:require_authenticated_user`, `:require_live_dashboard_access`) and an `on_mount` list, gating on `Scope.live_dashboard?/1` — membership in the `:live_dashboard_user_ids` app env, set from the comma-separated `LIVE_DASHBOARD_USER_IDS` env var (user **ids**, not emails; matched case-insensitively; empty by default, so production admits nobody until it is configured). Three things are load-bearing:
- **Both guards are needed.** `live_dashboard/2` mounts its CSS and JS as ordinary controller routes that no `on_mount` hook runs for, while the LiveView's connected mount arrives over the socket and never passes through the pipeline. Drop either and one half is unguarded.
- **Only ever mount `live_dashboard/2` once.** A second mount collides on the `:live_dashboard` live_session name, and the dashboard resolves its internal links against a single `@live_dashboard_prefix` recorded by whichever mount compiled first — so the loser's navigation silently points into the wrong prefix. That is why the dev/prod difference is expressed as compile-time pipeline and `on_mount` values rather than as two routes.
- **`csp_nonce_assign_key: :csp_nonce` is required.** The dashboard layout renders an inline `<script>` defining `window.LiveDashboard`, and its own bundle reads `window.LiveDashboard.customHooks` on load. [SecurityHeaders](tabletop/lib/tabletop_web/plugs/security_headers.ex) sets no `'unsafe-inline'` in `script-src`, so without the nonce the browser blocks that script, the bundle throws before connecting, and the page renders dead and never updates.

Dashboard access is deliberately independent of `:admin_ids` (tournament admin) — both are user-id lists, but they are different privileges, so a tournament admin is not automatically a dashboard user. `live_dashboard?/1` matches case-insensitively; `admin?/1` does not.

**Grafana Cloud database observability.** [infrastructure/monitoring/](infrastructure/monitoring/) ships the external counterpart: a read-only `db-o11y` role ([db-o11y-setup.sql](infrastructure/monitoring/db-o11y-setup.sql)) plus a Grafana Alloy collector deployed as its own Fly app. It is a pure infrastructure concern — no Elixir code participates — but two things constrain edits elsewhere:
- **The four `-c` flags on the Postgres process command are load-bearing.** `shared_preload_libraries`, `compute_query_id=on`, `pg_stat_statements.track=all` and `track_activity_query_size=4096` are start-up flags, so they live in [postgres.toml](infrastructure/fly/postgres.toml) and can't be set at runtime. They are deployment-only — the dev Postgres in [docker-compose.yml](docker-compose.yml) runs stock, so none of this works locally. Dropping `compute_query_id` in particular breaks the query_samples collector silently: it joins `pg_stat_activity` to `pg_stat_statements` on `query_id`, and PG18's default `auto` leaves that null for anything the module didn't ask about.
- **The collector runs inside Fly, not from Grafana Cloud.** `fabtabletop-db` publishes no ports, so it is reachable only over 6PN — which also means the DSN uses `sslmode=disable` (the `postgres:*-alpine` image serves no certificate; 6PN is already WireGuard-encrypted), not the `sslmode=require` in Grafana's docs.

**Ecto Stats.** The dashboard's Ecto Stats page is powered by the optional [ecto_psql_extras](https://hexdocs.pm/ecto_psql_extras) dep (a normal runtime dep, not dev-only, since the dashboard is mounted in production). `ecto_repos: [Tabletop.Repo]` is passed explicitly instead of leaving the dashboard to auto-discover via an `Ecto.Repo.all_running/0` RPC per mount. The `calls` and `outliers` tabs additionally need the Postgres `pg_stat_statements` extension — `EctoPSQLExtras.queries/1` probes `pg_available_extensions` and simply omits those two tabs when it is absent, so a database without it degrades quietly rather than erroring. Only the deployed Postgres preloads the module ([infrastructure/fly/postgres.toml](infrastructure/fly/postgres.toml)), and even there the extension itself still has to be created once per database. Neither the dev Postgres nor CI's preloads it, which is why that `CREATE EXTENSION` is a documented one-liner rather than a migration — a migration would fail the suite. So the other 29 tabs work everywhere; these two only in production.

**Password reset.** `/users/reset-password` ([ForgotPassword](tabletop/lib/tabletop_web/live/user_live/forgot_password.ex)) mails a `"reset_password"` `UserToken` (24 h validity); `/users/reset-password/:token` ([ResetPassword](tabletop/lib/tabletop_web/live/user_live/reset_password.ex)) verifies it on both the dead and connected mount. `Accounts.reset_user_password/2` deletes *every* token for the user (burns the link, kills existing sessions — the LiveView also calls `UserAuth.disconnect_sessions/1`) and confirms an unconfirmed account, since completing a reset proves mailbox control. The minimum password length lives in one place, `User.min_password_length/0`, and every path (register / settings / reset) validates through `validate_password/2`.

### Metrics & observability

Prometheus metrics via **PromEx**, scraped by Fly's managed Prometheus. Three moving parts — keep them in sync or metrics silently stop.

- **[Tabletop.PromEx](tabletop/lib/tabletop/prom_ex.ex)** — the PromEx module. Stock plugins (Application, Beam, Phoenix, Ecto, PhoenixLiveView) each have a matching pre-built Grafana dashboard listed in `dashboards/0`; export with `mix prom_ex.dashboard.export --dashboard <name> --stdout`. `grafana: :disabled` — dashboards are imported by hand, not pushed on boot.
- **[Tabletop.PromEx.MetricsServer](tabletop/lib/tabletop/prom_ex/metrics_server.ex)** — a Bandit listener on its own port (`:metrics_port`, default 9091), **not** part of `TabletopWeb.Endpoint`. PromEx's built-in metrics server is `Plug.Cowboy`-based; serving the plug on Bandit avoids a second web server in the release. Binds `{0,0,0,0,0,0,0,0}` because Fly's private network is IPv6. Set `:metrics_port` to `nil` to disable (the test env does — a fixed port would collide across concurrent suites).
- **[Tabletop.Telemetry](tabletop/lib/tabletop/telemetry.ex)** — the single source of truth for the app's own `:telemetry` event names *and* the emit helpers that normalise metadata. Metric definitions live in [Tabletop.PromEx.GamePlugin](tabletop/lib/tabletop/prom_ex/game_plugin.ex); both sides reference the name functions here.

**The rule that matters:** a `:telemetry` event with no attached handler fails *silently*. Renaming an event, or reading a measurement key the emitter doesn't send, produces no error — just a metric that stays permanently empty in Grafana. [telemetry_test.exs](tabletop/test/tabletop/telemetry_test.exs) exists to turn that silence into a test failure; when you add an event, add it to `@event_names` **and** `events/0` there.

**Tag cardinality:** Prometheus creates one series per label combination, and Fly drops high-cardinality custom metrics outright. Never tag with a `game_id`, `user_id`, card name, or raw exit reason. `Telemetry.session_action/2` tags only the action *name* (never its payload) and `session_stop/1` collapses unbounded exit reasons to `:abnormal` for exactly this reason.

**Domain metrics** (`tabletop_prom_ex_game_*`) cover what stock dashboards can't: card-scan hit rate + Hamming-distance distribution (is `@art_threshold`/`@full_threshold` in [cards.ex](tabletop/lib/tabletop/cards.ex) still right against real sleeves?), game-session count and abnormal stops, leave-timer outcomes, camera-relay joins/signalling, and `Swiss.pair/3` duration. Pairing is timed at the **context** boundary in [tournaments.ex](tabletop/lib/tabletop/tournaments.ex), not inside `Swiss`, so the pairing engine stays pure.

`Cards.best_phash_match/2` mirrors the arm ranking inside `find_by_p_hash_similarity/1`'s SQL so a match's distance can be reported without a second query — if you change the thresholds or the arms, change both.

Metrics are per-machine and in-memory, so they don't survive a restart: a deploy resets every counter and gaps the gauges. Query with `rate()`/`increase()` and read a gap as "deployed", not as zero. The machine stays up (`auto_stop_machines = 'off'`, `min_machines_running = 1`), so the series are otherwise continuous.

**Tracing** is separate from the above: OpenTelemetry spans **pushed** over OTLP to Grafana Tempo (push, not scrape — the only model that works on a sleeping machine). [Tabletop.Tracing](tabletop/lib/tabletop/tracing.ex) attaches the handlers from `Application.start/2` before the endpoint serves; spans come from Bandit, Phoenix (including LiveView `mount`/`handle_event` — where most of this app's behaviour actually lives) and Ecto. No application code emits spans directly.

Two things to know before touching it:
- **Order in `setup/0` matters** — Bandit first, so its span parents the Phoenix span instead of becoming a sibling.
- **Disabled unless configured.** The exporter defaults to `http://localhost:4318` and logs every failed batch, so `config.exs` ships `traces_exporter: :none` and `runtime.exs` flips it to `:otlp` only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Handlers attach regardless, so the instrumented path is identical either way. `Tabletop.Tracing.exporting?/0` distinguishes "off" from "on but rejected".

`OpentelemetryEcto` runs with `db_statement: :enabled` — safe because Ecto parameterises queries, so the recorded SQL holds `$1`/`$2` placeholders and never user values. To inspect spans locally, set `traces_exporter: {:otel_exporter_stdout, []}` in `dev.exs`.

**Error tracking** is [Sentry](tabletop/lib/tabletop/application.ex), deliberately *not* overlapping the above: Tempo records exceptions but has no issue model (no grouping, dedup, or regression detection), and metrics cannot see a crash at all. Enabled only when `SENTRY_DSN` is set — the SDK reads that env var itself and is disabled without it, so dev and test need no opt-out. 

## Conventions worth knowing

- The Elixir app is a sub-directory (`tabletop/`), not the repo root. Run `mix` from there.
- Don't move ephemeral game state into Ecto — sessions are intentionally in-memory; persistence is limited to `Game` metadata.
- When adding a new `GameSession` action, both `dispatch/2` (in `game_session.ex`) and the corresponding `GameState` transform must be added; broadcasts go out automatically via `broadcast_update/4`.
- Don't add any Elixir `@spec` documentation, but be sure to document other functions where necessary.
- **Tile positions are *board* coordinates, and the viewer adapts them.** `GameState.tile_positions` holds percentages of the video frame in the frame of the player who placed them — the server has no idea how any viewer is looking at that board. So `game_tiles/1` emits them as `--tile-x`/`--tile-y` custom properties (never `left`/`top`) on tiles inside a `#tile-layer-<context>` overlay that covers exactly the rect the board is drawn in — `inset-0` where the canvas fills its container, sized per frame by `webrtc.js` for `:remote`, where the canvas is letterboxed inside `#game-area`. `.game-tile` in `app.css` turns those into `left`/`top` and mirrors them (`100% - x`) under `[data-board-flipped="true"]`, which the game hook sets whenever the opponent's canvas carries its default 180° rotation; the tiles themselves stay upright so their labels stay readable. Bake `left`/`top` into a tile and it pins to the placer's side of the table, showing up mirrored on the opponent's screen.
- **Client-managed DOM needs `phx-update="ignore"`.** Any element whose state is driven by JavaScript — a colocated hook, `localStorage`, or a JS-set `class`/`checked`/`value` — that sits inside a LiveView-rendered region will be reset to its static server markup on the next re-render, silently desyncing the visible UI from the real (client-side) state. The server can't render the truth because it doesn't know the client state, so mark the element (or a stable-`id` wrapper) `phx-update="ignore"` and let the hook own it after the initial render. Examples in the game show page: `#opponent-volume-control` (hover slider + mute icon, client-driven), `#connection-status`, the user-settings `#sound-settings` block, and the whole `#settings-dialog` (flip/debug toggles + effect & opponent volume sliders). Symptom when it's missing: a control "resets itself" on the UI while the underlying behaviour stays correct.

# Important instructions

- If you discover a pre existing issue to anything, please fix it and make note of it, do not ignore and pass it off as a comment.
- Do not create new git branches/stage files/commit, please leave any work for manual inspection and commiting.
