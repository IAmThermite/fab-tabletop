// Encoder tuning shared by every *sending* peer connection — the game link in
// webrtc.js and the phone-as-camera relay in phone_camera_relay.js.
//
// WebRTC's defaults are tuned for talking heads, which is close to the opposite
// of what this app sends: a near-static card table where the only thing that
// matters is whether the opponent can read small print. Three of those defaults
// actively work against that, and none of them are negotiated for you — an
// unconfigured sender just silently settles for less.

// Chrome caps a single unconfigured video stream at roughly 2 Mbps no matter
// how much headroom the link has. 8 Mbps is generous for 1080p30 of mostly
// static content and lets bandwidth estimation actually use a good connection;
// congestion control still ramps below it, so this is a ceiling, not a floor.
export const MAX_VIDEO_BITRATE = 8_000_000

export const TARGET_FRAMERATE = 30

// Codec ranking, best first. VP9 holds far more spatial detail than VP8 or
// H.264 baseline at the same bitrate on a static, detail-dense scene. AV1 is
// better still per bit, but its real-time encoder is software-only on most
// machines and would compete with the scanner's OpenCV work — so it sits behind
// VP9 as the fallback for peers that lack it. Flip the order here to try AV1
// first, and watch `qualityLimitationReason` for "cpu" if you do.
export const PREFERRED_VIDEO_CODECS = ["video/VP9", "video/AV1"]

/**
 * Marks a track (or every video track of a stream) as detail-critical.
 *
 * `contentHint = "detail"` tells the encoder to protect spatial detail at the
 * expense of temporal smoothness. That is the correct trade for a card table,
 * and it is the cheapest single quality win available here. It also survives
 * canvas capture, so a transformed stream keeps the hint.
 *
 * Worth setting on *received* tracks too when they get forwarded on: the
 * sender reads the hint off the track it is handed, so hinting the phone's
 * incoming track improves the desktop's re-encode of it.
 */
export function hintVideoDetail(source) {
  if (!source) return
  const tracks =
    typeof source.getVideoTracks === "function"
      ? source.getVideoTracks()
      : source.kind === "video"
        ? [source]
        : []
  tracks.forEach((track) => {
    track.contentHint = "detail"
  })
}

/**
 * Re-ranks the video codec list so negotiation lands on the codec that keeps
 * the most detail per bit.
 *
 * Must run before `createOffer` / `createAnswer` to reach the SDP. Nothing is
 * filtered out — RTX and FEC entries stay put and the browser's own relative
 * ordering is preserved within each rank — so a peer without VP9 still
 * negotiates whatever it does support.
 */
export function preferVideoCodecs(pc, preferred = PREFERRED_VIDEO_CODECS) {
  if (!pc) return
  if (typeof RTCRtpSender === "undefined" || typeof RTCRtpSender.getCapabilities !== "function") {
    return
  }

  const transceiver = pc
    .getTransceivers()
    .find((t) => (t.sender?.track?.kind || t.receiver?.track?.kind) === "video")
  if (!transceiver || typeof transceiver.setCodecPreferences !== "function") return

  try {
    const codecs = RTCRtpSender.getCapabilities("video")?.codecs
    if (!codecs?.length) return

    const rank = (codec) => {
      const i = preferred.indexOf(codec.mimeType)
      return i === -1 ? preferred.length : i
    }

    const ordered = codecs
      .map((codec, i) => ({ codec, i }))
      .sort((a, b) => rank(a.codec) - rank(b.codec) || a.i - b.i)
      .map(({ codec }) => codec)

    transceiver.setCodecPreferences(ordered)
  } catch (err) {
    console.warn("[WebRTC] Could not set codec preferences:", err)
  }
}

/**
 * Applies the send-side encoding parameters. Call after `setLocalDescription`
 * (the encodings only exist once the sender is negotiated) and again after any
 * `replaceTrack`.
 *
 * `degradationPreference` is the important one: the default, "balanced", sheds
 * *resolution* under load — exactly the dimension that decides whether card
 * text is legible. "maintain-resolution" trades framerate away instead, so a
 * congested link yields a few sharp frames a second rather than 30 blurry ones.
 */
export async function tuneVideoSender(
  pc,
  { maxBitrate = MAX_VIDEO_BITRATE, maxFramerate = TARGET_FRAMERATE } = {},
) {
  const sender = pc?.getSenders().find((s) => s.track?.kind === "video")
  if (!sender) return

  try {
    const params = sender.getParameters()
    if (!params.encodings || params.encodings.length === 0) {
      params.encodings = [{}]
    }
    params.encodings[0].maxBitrate = maxBitrate
    params.encodings[0].maxFramerate = maxFramerate
    // Never ship a pre-downscaled frame to save bits.
    params.encodings[0].scaleResolutionDownBy = 1
    params.degradationPreference = "maintain-resolution"
    await sender.setParameters(params)
  } catch (err) {
    console.warn("[WebRTC] Could not tune video sender:", err)
  }
}

/**
 * Outbound video health, flattened for logging.
 *
 * `limitation` (`qualityLimitationReason`) is the one number that says which
 * knob is worth turning: "bandwidth" means the link is the ceiling, "cpu" means
 * something local is starving the encoder (canvas work, an OpenCV scan, AV1),
 * and "none" at a low `width` means MAX_VIDEO_BITRATE itself is the ceiling.
 */
export async function readVideoStats(pc) {
  if (!pc) return null

  const stats = await pc.getStats()
  let out = null

  stats.forEach((report) => {
    if (report.type !== "outbound-rtp" || report.kind !== "video") return
    out = {
      width: report.frameWidth,
      height: report.frameHeight,
      fps: report.framesPerSecond,
      limitation: report.qualityLimitationReason,
      targetKbps: report.targetBitrate ? Math.round(report.targetBitrate / 1000) : null,
      codec: stats.get(report.codecId)?.mimeType || null,
    }
  })

  return out
}
