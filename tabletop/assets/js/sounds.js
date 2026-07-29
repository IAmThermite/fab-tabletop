// Client-side audio cue engine.
//
// A framework-agnostic singleton that plays short, synthesized (Web Audio)
// cues for game/connection events and owns the per-device sound preferences
// (on/off + volume, persisted in localStorage under the `tabletop:*` convention).
//
// Cues are generated from oscillator "tone" specs — there are no audio files
// and no asset-pipeline involvement. The emit path is written so a future
// `{ kind: "file", src }` cue would also work (drop-in priv/static asset), but
// nothing ships that way today.
//
// Imported by the `.Sounds` / `.SoundSettings` / `.GameVideo` hooks. Never
// imported by the scanner Web Worker, so `window`/`AudioContext` are available.

const VOLUME_KEY = "tabletop:sound-volume"
const DEFAULT_VOLUME = 0.6
const DEFAULT_DEBOUNCE_MS = 300

// Cue registry. Each entry is a `tone` spec:
//   notes: [{ freq, t, dur }]  — t/dur in seconds, t relative to play start
//   type:  oscillator wave ("sine" | "triangle" | ...)
//   gain:  per-cue level multiplier (0..1), applied on top of user volume
//   debounceMs: optional per-cue de-dup window
const CUES = {
  // Opponent presence (fired client-side from the WebRTC status machine).
  opponent_join: {
    notes: [{ freq: 587.33, t: 0, dur: 0.12 }, { freq: 880.0, t: 0.1, dur: 0.18 }],
    type: "sine",
    gain: 0.5,
  },
  opponent_reconnect: {
    notes: [
      { freq: 659.25, t: 0, dur: 0.08 },
      { freq: 880.0, t: 0.07, dur: 0.08 },
      { freq: 1046.5, t: 0.14, dur: 0.14 },
    ],
    type: "sine",
    gain: 0.5,
  },
  opponent_dropped: {
    notes: [{ freq: 659.25, t: 0, dur: 0.13 }, { freq: 440.0, t: 0.11, dur: 0.2 }],
    type: "triangle",
    gain: 0.5,
  },

  // Game lifecycle (fired server-side via push_event).
  game_ended: {
    notes: [
      { freq: 659.25, t: 0, dur: 0.16 },
      { freq: 523.25, t: 0.15, dur: 0.16 },
      { freq: 392.0, t: 0.3, dur: 0.3 },
    ],
    type: "sine",
    gain: 0.55,
  },

  // Media toggles. Self-blips fire client-side; opponent's fire server-side.
  mic_off: { notes: [{ freq: 330.0, t: 0, dur: 0.09 }], type: "sine", gain: 0.45 },
  mic_on: { notes: [{ freq: 523.25, t: 0, dur: 0.09 }], type: "sine", gain: 0.45 },
  camera_off: { notes: [{ freq: 392.0, t: 0, dur: 0.09 }], type: "sine", gain: 0.45 },
  camera_on: { notes: [{ freq: 622.25, t: 0, dur: 0.09 }], type: "sine", gain: 0.45 },

  // Short tick played while a volume slider moves, so the player hears the
  // resulting loudness. Throttled by debounce so a drag doesn't machine-gun.
  volume_blip: { notes: [{ freq: 660.0, t: 0, dur: 0.06 }], type: "sine", gain: 0.5, debounceMs: 200 },

  // Tournament events (fired server-side via the user-notification stream, on
  // whatever page the player is on — see TabletopWeb.UserNotifications).
  tournament_check_in: {
    notes: [{ freq: 523.25, t: 0, dur: 0.1 }, { freq: 659.25, t: 0.09, dur: 0.18 }],
    type: "sine",
    gain: 0.5,
  },
  tournament_match_ready: {
    notes: [
      { freq: 659.25, t: 0, dur: 0.1 },
      { freq: 783.99, t: 0.09, dur: 0.1 },
      { freq: 987.77, t: 0.18, dur: 0.2 },
    ],
    type: "sine",
    gain: 0.5,
  },
  tournament_result: {
    notes: [{ freq: 783.99, t: 0, dur: 0.08 }, { freq: 1046.5, t: 0.07, dur: 0.16 }],
    type: "triangle",
    gain: 0.45,
  },
  tournament_finished: {
    notes: [
      { freq: 523.25, t: 0, dur: 0.12 },
      { freq: 659.25, t: 0.1, dur: 0.12 },
      { freq: 783.99, t: 0.2, dur: 0.12 },
      { freq: 1046.5, t: 0.3, dur: 0.3 },
    ],
    type: "sine",
    gain: 0.55,
  },
}

class SoundEngine {
  constructor() {
    this._ctx = null
    this._lastFired = new Map()
    this._listeners = new Set()

    if (typeof window === "undefined") return

    // Unlock the AudioContext on the first user gesture (browsers block audio
    // until then). The game flow gestures heavily before any cue can fire.
    const unlock = () => {
      this.unlock()
      window.removeEventListener("pointerdown", unlock, true)
      window.removeEventListener("keydown", unlock, true)
      window.removeEventListener("touchstart", unlock, true)
    }
    window.addEventListener("pointerdown", unlock, true)
    window.addEventListener("keydown", unlock, true)
    window.addEventListener("touchstart", unlock, true)

    // Cross-tab/page sync: the `storage` event fires in *other* tabs only, so
    // same-page sync is handled by _notify() inside setVolume.
    window.addEventListener("storage", (e) => {
      if (e.key === VOLUME_KEY) this._notify()
    })
  }

  // --- Preferences ---

  getVolume() {
    const v = parseFloat(localStorage.getItem(VOLUME_KEY))
    if (Number.isNaN(v)) return DEFAULT_VOLUME
    return Math.min(1, Math.max(0, v))
  }

  setVolume(value) {
    const clamped = Math.min(1, Math.max(0, value))
    localStorage.setItem(VOLUME_KEY, String(clamped))
    this._notify()
  }

  // Subscribe to volume changes. Returns an unsubscribe fn. Used to keep the
  // effect-volume sliders (settings dialog + settings page) in sync.
  onChange(cb) {
    this._listeners.add(cb)
    return () => this._listeners.delete(cb)
  }

  _notify() {
    const state = { volume: this.getVolume() }
    this._listeners.forEach((cb) => {
      try {
        cb(state)
      } catch (_e) {
        // never let a misbehaving listener break the engine
      }
    })
  }

  // --- Playback ---

  unlock() {
    const ctx = this._ensureContext()
    if (ctx && ctx.state === "suspended") ctx.resume().catch(() => {})
  }

  // Play a named cue. No-op if the cue is unknown, the volume is 0, the
  // debounce window hasn't elapsed, or the AudioContext can't run yet.
  play(cue, opts = {}) {
    const def = CUES[cue]
    if (!def) return

    const dedupeKey = opts.dedupeKey || cue
    const debounceMs = def.debounceMs != null ? def.debounceMs : DEFAULT_DEBOUNCE_MS
    const now = Date.now()
    const last = this._lastFired.get(dedupeKey)
    if (last != null && now - last < debounceMs) return

    const ctx = this._ensureContext()
    if (!ctx) return
    if (ctx.state === "suspended") {
      ctx.resume().catch(() => {})
      if (ctx.state !== "running") return // not yet unlocked — drop silently
    }

    this._lastFired.set(dedupeKey, now)

    const userVolume = opts.volume != null ? opts.volume : this.getVolume()
    const level = userVolume * (def.gain != null ? def.gain : 0.5)
    if (level <= 0) return
    this._emitTone(ctx, def, level)
  }

  _emitTone(ctx, def, level) {
    const start = ctx.currentTime
    const type = def.type || "sine"
    for (const note of def.notes) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.type = type
      osc.frequency.setValueAtTime(note.freq, start + note.t)

      const t0 = start + note.t
      const t1 = t0 + note.dur
      // Short attack, exponential decay (can't ramp to 0, so use a tiny floor).
      gain.gain.setValueAtTime(0.0001, t0)
      gain.gain.exponentialRampToValueAtTime(level, t0 + 0.006)
      gain.gain.exponentialRampToValueAtTime(0.0001, t1)

      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.start(t0)
      osc.stop(t1 + 0.02)
    }
  }

  _ensureContext() {
    if (this._ctx) return this._ctx
    if (typeof window === "undefined") return null
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) return null
    try {
      this._ctx = new AC()
    } catch (_e) {
      return null
    }
    return this._ctx
  }
}

export const sounds = new SoundEngine()
