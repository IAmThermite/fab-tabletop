import { Socket } from "phoenix"
import { startVideoFrameLoop } from "./video_frame_loop"
import {
  TARGET_FRAMERATE,
  hintVideoDetail,
  preferVideoCodecs,
  readVideoStats,
  tuneVideoSender,
} from "./webrtc_tuning"

const ICE_SERVERS = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun1.l.google.com:19302" },
  // Add TURN server config for production:
  // { urls: "turn:your-coturn-server:3478", username: "user", credential: "pass" },
]

// Capture resolution. Deliberately not 4K: webcams generally only serve 2160p
// as low-framerate MJPEG, the encoder scales it back down to fit the bitrate
// anyway, and the extra decode/canvas work pushes the encoder into CPU-limited
// degradation — which costs more detail than the extra pixels ever bought. This
// also matches what the pre-join and camera-setup previews capture, so the
// zoom/rotation calibration made there describes the same frame.
const CAPTURE_WIDTH = 1920
const CAPTURE_HEIGHT = 1080

// Set `tabletop:debug-webrtc` to "true" in localStorage to log outbound video
// health (resolution, framerate, codec, bitrate, limitation reason).
const STATS_LOG_INTERVAL_MS = 5000

export default class WebRTCManager {
  constructor({ token, gameId, localVideoEl, remoteVideoEl, tileLayerEl, onStatusChange, micEnabled = true, cameraEnabled = true }) {
    this.token = token
    this.gameId = gameId
    this.localVideoEl = localVideoEl
    this.remoteVideoEl = remoteVideoEl
    // Overlay holding the opponent's tiles. Tile coordinates are percentages of
    // the board, so the overlay has to track the letterboxed video rect rather
    // than the container it is centred in.
    this.tileLayerEl = tileLayerEl || null
    this.onStatusChange = onStatusChange || (() => { })

    this.socket = null
    this.channel = null
    this.peerConnection = null
    this.localStream = null
    this.cameraEnabled = cameraEnabled
    this.micEnabled = micEnabled
    this._status = null
    // Set when the server hands this player's seat to a newer connection (see
    // TabletopWeb.ChannelSeat). Terminal — this tab does not signal again.
    this._superseded = false

    // Transformed stream for sending zoom/rotation to peer
    this._streamForPeer = null
    this._localCanvasEl = null
    this._stopLocalTransformLoop = null
    this._canvasStream = null

    // Remote-board layout (see _startRemoteLayout)
    this._onRemoteLayout = null
    this._containerObserver = null
    this._statsTimer = null
  }

  async start() {
    this._setStatus("connecting")

    // Capture local media first so tracks are ready before signaling.
    // Lock to 16:9 so previews and the remote feed share one aspect ratio —
    // tile coordinates are percentages of the frame, so a preview cropped to a
    // different aspect than the sent frame would place tiles where the opponent
    // doesn't see them.
    const videoBase = {
      width: { ideal: CAPTURE_WIDTH },
      height: { ideal: CAPTURE_HEIGHT },
      frameRate: { ideal: TARGET_FRAMERATE },
    }
    try {
      try {
        this.localStream = await navigator.mediaDevices.getUserMedia({
          video: { ...videoBase, aspectRatio: { exact: 16 / 9 } },
          audio: true,
        })
      } catch (err) {
        if (err && err.name === "OverconstrainedError") {
          console.warn("[WebRTC] Camera rejected 16:9 constraint, falling back")
          this.localStream = await navigator.mediaDevices.getUserMedia({
            video: videoBase,
            audio: true,
          })
        } else {
          throw err
        }
      }
      hintVideoDetail(this.localStream)
      this.localVideoEl.srcObject = this.localStream
      await this.localVideoEl.play().catch(() => { })
      this._streamForPeer = this._createTransformedStream()
      // Apply the persisted mic/camera state (recovered from GameSession on
      // mount) to the freshly acquired tracks.
      this._applyTrackEnabled()
    } catch (err) {
      console.error("[WebRTC] Failed to get user media:", err)
      this._setStatus("no_camera")
    }

    // Connect the Phoenix socket
    this.socket = new Socket("/socket", { params: { token: this.token } })
    this.socket.connect()

    // Join the game channel
    this.channel = this.socket.channel(`game:${this.gameId}`, {})

    // The server nominates one player to make the offer, so both of us
    // reconnecting in the same instant still produces exactly one — see
    // `TabletopWeb.GameChannel.request_offer/1`. An opponent arriving is not
    // itself the trigger; `peer_joined` and `peer_exists` only report.
    this.channel.on("make_offer", () => this._createOffer())
    this.channel.on("peer_joined", () => console.log("[WebRTC] Opponent joined the channel"))
    this.channel.on("peer_exists", () => console.log("[WebRTC] Opponent already in the channel"))
    this.channel.on("offer", (msg) => this._handleOffer(msg))
    this.channel.on("answer", (msg) => this._handleAnswer(msg))
    this.channel.on("ice_candidate", (msg) => this._handleIceCandidate(msg))
    this.channel.on("peer_left", () => this._handlePeerLeft())
    this.channel.on("superseded", () => this._handleSuperseded())

    this.channel.join()
      .receive("ok", () => {
        console.log("[WebRTC] Joined game channel")
        // Only set "waiting" if we haven't already progressed further
        // (e.g., signaling may have completed before the join ack arrives)
        if (this._status !== "connected") {
          this._setStatus("waiting")
        }
      })
      .receive("error", (resp) => {
        console.error("[WebRTC] Failed to join channel:", resp)
        this._setStatus("error")
      })
  }

  setCameraEnabled(enabled) {
    this.cameraEnabled = enabled
    this._applyTrackEnabled()
  }

  setMicEnabled(enabled) {
    this.micEnabled = enabled
    this._applyTrackEnabled()
  }

  // Pushes the current cameraEnabled / micEnabled state down to every track we
  // hold. It has to cover all of them, not just the webcam: when the phone is
  // the video source `_streamForPeer` *is* the phone's stream, so touching only
  // `localStream` would leave the camera toggle and mic mute doing nothing
  // while the phone kept transmitting. Safe to call before media is acquired.
  _applyTrackEnabled() {
    const videoTracks = new Set()
    const audioTracks = new Set()

    for (const stream of [this.localStream, this._externalStream, this._canvasStream, this._streamForPeer]) {
      if (!stream) continue
      stream.getVideoTracks().forEach((t) => videoTracks.add(t))
      stream.getAudioTracks().forEach((t) => audioTracks.add(t))
    }

    videoTracks.forEach((t) => { t.enabled = this.cameraEnabled })
    audioTracks.forEach((t) => { t.enabled = this.micEnabled })
  }

  async setExternalVideoSource(stream) {
    this._externalStream = stream
    hintVideoDetail(stream)

    // Update local preview to show the external source
    this.localVideoEl.srcObject = stream
    this.localVideoEl.play().catch(() => { })

    // Rebuild the transformed stream from the new source
    this._stopLocalTransform()
    this._streamForPeer = this._createTransformedStream()

    // Newly built tracks start enabled, so re-assert the toggle state before
    // they reach the peer — otherwise switching source silently un-mutes.
    this._applyTrackEnabled()

    await this._replacePeerVideoTrack()
  }

  async clearExternalVideoSource() {
    if (!this._externalStream) return
    this._externalStream = null

    // Restore the original webcam stream
    this.localVideoEl.srcObject = this.localStream
    this.localVideoEl.play().catch(() => { })

    // Rebuild the transformed stream from the webcam
    this._stopLocalTransform()
    this._streamForPeer = this._createTransformedStream()
    this._applyTrackEnabled()

    await this._replacePeerVideoTrack()
  }

  // Swaps the outbound video track to whatever `_streamForPeer` now holds and
  // re-applies the encoding parameters (a fresh track can arrive with default
  // encodings).
  async _replacePeerVideoTrack() {
    if (!this.peerConnection) return

    const newVideoTrack = this._streamForPeer?.getVideoTracks()[0]
    const sender = this.peerConnection
      .getSenders()
      .find((s) => s.track?.kind === "video")
    if (sender && newVideoTrack) {
      await sender.replaceTrack(newVideoTrack)
      await tuneVideoSender(this.peerConnection)
    }
  }

  _stopLocalTransform() {
    if (this._stopLocalTransformLoop) {
      this._stopLocalTransformLoop()
      this._stopLocalTransformLoop = null
    }
    if (this._canvasStream) {
      this._canvasStream.getTracks().forEach((t) => t.stop())
      this._canvasStream = null
    }
    this._localCanvasEl = null
  }

  disconnect() {
    this.stopStatsLogging()
    this._stopLocalTransform()
    this._streamForPeer = null
    this._stopRemoteLayout()

    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }

    if (this.localStream) {
      this.localStream.getTracks().forEach((track) => track.stop())
      this.localStream = null
    }

    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }

    if (this.socket) {
      this.socket.disconnect()
      this.socket = null
    }
  }

  // -- Diagnostics --

  // One-shot read of the outbound video stats. Also available from the console
  // for ad-hoc checks during a real game.
  videoStats() {
    return readVideoStats(this.peerConnection)
  }

  startStatsLogging(intervalMs = STATS_LOG_INTERVAL_MS) {
    if (this._statsTimer) return

    this._statsTimer = setInterval(async () => {
      const s = await this.videoStats()
      if (!s) return
      console.log(
        `[WebRTC] out ${s.width}x${s.height} @${s.fps ?? "?"}fps ` +
        `${s.codec || "?"} ${s.targetKbps ?? "?"}kbps limited=${s.limitation}`,
      )
    }, intervalMs)
  }

  stopStatsLogging() {
    if (!this._statsTimer) return
    clearInterval(this._statsTimer)
    this._statsTimer = null
  }

  // -- Private methods --

  _setStatus(status) {
    this._status = status
    this.onStatusChange(status)
  }

  // Signalling is emitted from async paths that can resume after the channel is
  // gone — a superseded tab tears its channel down mid-`_createOffer`. Dropping
  // the message is the right outcome there, so this never throws on a null
  // channel.
  _push(event, payload) {
    if (!this.channel) return
    this.channel.push(event, payload)
  }

  _createPeerConnection() {
    if (this.peerConnection) {
      this.peerConnection.close()
    }

    this.peerConnection = new RTCPeerConnection({ iceServers: ICE_SERVERS })

    // Add local tracks to the connection (use transformed stream if available)
    const streamToSend = this._streamForPeer || this.localStream
    if (streamToSend) {
      streamToSend.getTracks().forEach((track) => {
        this.peerConnection.addTrack(track, streamToSend)
      })
    }

    // When we get ICE candidates, send them to the other peer
    this.peerConnection.onicecandidate = (event) => {
      if (event.candidate) {
        this._push("ice_candidate", { candidate: event.candidate })
      }
    }

    // When we receive remote tracks
    this.peerConnection.ontrack = (event) => {
      this.remoteVideoEl.srcObject = event.streams[0]
      this.remoteVideoEl.play().catch(() => { })
      this._startRemoteLayout()
      this._setStatus("connected")
    }

    this.peerConnection.oniceconnectionstatechange = () => {
      const state = this.peerConnection?.iceConnectionState
      console.log("[WebRTC] ICE connection state:", state)

      if (state === "disconnected" || state === "failed") {
        this._setStatus("disconnected")
      } else if (state === "connected" || state === "completed") {
        this._setStatus("connected")
        // A blip that recovers doesn't fire `ontrack` again, so re-assert the
        // board layout here rather than relying on that path.
        this.applyRemoteLayout()
      }
    }
  }

  async _createOffer() {
    if (this._superseded) return

    try {
      console.log("[WebRTC] Creating offer")
      this._createPeerConnection()
      preferVideoCodecs(this.peerConnection)

      const offer = await this.peerConnection.createOffer()
      await this.peerConnection.setLocalDescription(offer)

      this._push("offer", { sdp: this.peerConnection.localDescription })
      await tuneVideoSender(this.peerConnection)
    } catch (err) {
      console.error("[WebRTC] Error creating offer:", err)
      this._setStatus("error")
    }
  }

  async _handleOffer({ sdp }) {
    if (this._superseded) return

    try {
      console.log("[WebRTC] Received offer, creating answer")
      this._createPeerConnection()

      await this.peerConnection.setRemoteDescription(new RTCSessionDescription(sdp))

      // After setRemoteDescription so the preference applies to the transceiver
      // the offer associated, but before createAnswer so it reaches the SDP.
      preferVideoCodecs(this.peerConnection)

      const answer = await this.peerConnection.createAnswer()
      await this.peerConnection.setLocalDescription(answer)

      this._push("answer", { sdp: this.peerConnection.localDescription })
      await tuneVideoSender(this.peerConnection)
    } catch (err) {
      console.error("[WebRTC] Error handling offer:", err)
      this._setStatus("error")
    }
  }

  async _handleAnswer({ sdp }) {
    try {
      console.log("[WebRTC] Received answer")
      if (this.peerConnection) {
        await this.peerConnection.setRemoteDescription(new RTCSessionDescription(sdp))
        await tuneVideoSender(this.peerConnection)
      }
    } catch (err) {
      console.error("[WebRTC] Error handling answer:", err)
      this._setStatus("error")
    }
  }

  async _handleIceCandidate({ candidate }) {
    if (this.peerConnection && candidate) {
      try {
        await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
      } catch (err) {
        console.error("[WebRTC] Error adding ICE candidate:", err)
      }
    }
  }

  // The server gave this player's seat to a newer connection — usually the same
  // game opened in a second tab. Only one socket per player may sit on the
  // signalling topic (see TabletopWeb.ChannelSeat), so this tab releases the
  // camera and stops signalling rather than fighting the newer one for it. The
  // LiveView underneath stays live, so game state keeps updating here.
  _handleSuperseded() {
    console.warn("[WebRTC] Superseded — this game is open in a newer tab")
    this._superseded = true

    this.disconnect()
    this.remoteVideoEl.srcObject = null
    this._clearRemoteLayout()
    this._setStatus("superseded")
  }

  _handlePeerLeft() {
    console.log("[WebRTC] Peer left")
    this._stopRemoteLayout()

    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }

    this.remoteVideoEl.srcObject = null
    this._clearRemoteLayout()
    this._setStatus("waiting")
  }

  _createTransformedStream() {
    const sourceStream = this._externalStream || this.localStream
    if (!sourceStream) return null

    const zoom = parseFloat(localStorage.getItem("tabletop:camera-zoom") || "1")
    const rotation = parseFloat(localStorage.getItem("tabletop:camera-rotation") || "0")

    // No transforms needed — use raw stream directly. Skipping the canvas
    // entirely also skips a re-encode generation, so this is the good path.
    if (zoom === 1 && rotation === 0) {
      return sourceStream
    }

    // Create a hidden canvas to render transformed video
    this._localCanvasEl = document.createElement("canvas")
    const videoTrack = sourceStream.getVideoTracks()[0]
    const settings = videoTrack.getSettings()
    const sourceW = settings.width || CAPTURE_WIDTH
    const sourceH = settings.height || CAPTURE_HEIGHT

    // Size the canvas to the *cropped* region rather than to the full frame.
    // Zoom is a centre crop, so cropping to 1/zoom and then stretching back up
    // to full size would hand the encoder interpolated pixels — at 2x zoom, a
    // 1080p frame carrying 540p of real detail, with the bitrate spent smoothing
    // the difference. Encoding the crop at its true size spends every bit on
    // real pixels instead. Even dimensions so chroma subsampling has nothing to
    // round. Aspect ratio is preserved (a centre crop can't change it).
    const even = (n) => Math.max(2, Math.round(n / 2) * 2)
    this._localCanvasEl.width = even(sourceW / zoom)
    this._localCanvasEl.height = even(sourceH / zoom)

    const ctx = this._localCanvasEl.getContext("2d")
    ctx.imageSmoothingQuality = "high"
    const videoEl = this.localVideoEl
    const rad = rotation * Math.PI / 180

    const renderLocal = () => {
      const cw = this._localCanvasEl.width
      const ch = this._localCanvasEl.height
      const vw = videoEl.videoWidth
      const vh = videoEl.videoHeight

      // Zoom: crop source rectangle from center
      const sw = vw / zoom
      const sh = vh / zoom
      const sx = (vw - sw) / 2
      const sy = (vh - sh) / 2

      // Scale up to fill corners when rotated. At rotation 0 this resolves to
      // 1, so the crop is drawn 1:1 and no interpolation happens at all.
      const sinR = Math.abs(Math.sin(rad))
      const cosR = Math.abs(Math.cos(rad))
      const rotScale = Math.max(
        (cw * cosR + ch * sinR) / cw,
        (cw * sinR + ch * cosR) / ch
      )
      const dw = cw * rotScale
      const dh = ch * rotScale
      const dx = (cw - dw) / 2
      const dy = (ch - dh) / 2

      ctx.clearRect(0, 0, cw, ch)
      ctx.save()
      ctx.translate(cw / 2, ch / 2)
      ctx.rotate(rad)
      ctx.translate(-cw / 2, -ch / 2)
      ctx.drawImage(videoEl, sx, sy, sw, sh, dx, dy, dw, dh)
      ctx.restore()
    }
    this._stopLocalTransformLoop = startVideoFrameLoop(videoEl, renderLocal)

    this._canvasStream = this._localCanvasEl.captureStream(TARGET_FRAMERATE)

    // Combine canvas video track with audio tracks from the active source
    const combinedStream = new MediaStream()
    this._canvasStream.getVideoTracks().forEach(t => combinedStream.addTrack(t))
    sourceStream.getAudioTracks().forEach(t => combinedStream.addTrack(t))
    hintVideoDetail(combinedStream)

    return combinedStream
  }

  // -- Remote board layout --
  //
  // The opponent's board is the `<video>` element itself: nothing copies its
  // frames into a canvas, so the browser keeps its hardware video path and the
  // CPU it would have spent on that copy stays available to the encoder. All
  // that's left is sizing — the video is letterboxed inside #game-area, and the
  // tile overlay has to cover exactly the rect the board is drawn in.

  /**
   * Sizes the remote video, and the tile overlay tracking it, to the
   * aspect-fitted rect inside their container. Cheap enough to call on any
   * layout signal — and public because a LiveView patch of the tile layer drops
   * the inline size (the server markup carries none), so the game hook
   * re-applies this from `updated()`.
   */
  applyRemoteLayout() {
    const video = this.remoteVideoEl
    if (!video) return

    const vw = video.videoWidth
    const vh = video.videoHeight
    const container = video.parentElement
    if (!vw || !vh || !container) return

    const containerW = container.clientWidth
    const containerH = container.clientHeight
    if (!containerW || !containerH) return

    // Fit to the container while preserving the video's aspect ratio
    const videoAspect = vw / vh
    const containerAspect = containerW / containerH
    let displayW, displayH
    if (videoAspect > containerAspect) {
      displayW = containerW
      displayH = containerW / videoAspect
    } else {
      displayH = containerH
      displayW = containerH * videoAspect
    }

    video.style.width = displayW + "px"
    video.style.height = displayH + "px"

    if (this.tileLayerEl) {
      this.tileLayerEl.style.width = displayW + "px"
      this.tileLayerEl.style.height = displayH + "px"
    }
  }

  _startRemoteLayout() {
    if (this._onRemoteLayout) {
      this.applyRemoteLayout()
      return
    }

    this._onRemoteLayout = () => this.applyRemoteLayout()

    // `loadedmetadata` covers the first frame; `resize` on a video element
    // fires whenever the stream's intrinsic size changes — the peer switching
    // webcam → phone, or their encoder settling on a different resolution.
    this.remoteVideoEl.addEventListener("loadedmetadata", this._onRemoteLayout)
    this.remoteVideoEl.addEventListener("resize", this._onRemoteLayout)

    const container = this.remoteVideoEl.parentElement
    if (container && typeof ResizeObserver === "function") {
      this._containerObserver = new ResizeObserver(this._onRemoteLayout)
      this._containerObserver.observe(container)
    } else {
      window.addEventListener("resize", this._onRemoteLayout)
    }

    this.applyRemoteLayout()
  }

  _stopRemoteLayout() {
    if (!this._onRemoteLayout) return

    this.remoteVideoEl.removeEventListener("loadedmetadata", this._onRemoteLayout)
    this.remoteVideoEl.removeEventListener("resize", this._onRemoteLayout)
    window.removeEventListener("resize", this._onRemoteLayout)

    if (this._containerObserver) {
      this._containerObserver.disconnect()
      this._containerObserver = null
    }

    this._onRemoteLayout = null
  }

  _clearRemoteLayout() {
    if (this.remoteVideoEl) {
      this.remoteVideoEl.style.width = ""
      this.remoteVideoEl.style.height = ""
    }
    if (this.tileLayerEl) {
      // No stream, so no board rect to track — fall back to the full container.
      this.tileLayerEl.style.width = ""
      this.tileLayerEl.style.height = ""
    }
  }
}
