import { Socket } from "phoenix"

const ICE_SERVERS = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun1.l.google.com:19302" },
  // Add TURN server config for production:
  // { urls: "turn:your-coturn-server:3478", username: "user", credential: "pass" },
]

export default class WebRTCManager {
  constructor({ token, gameId, localVideoEl, remoteVideoEl, canvasEl, onStatusChange, onRemoteMediaStatus }) {
    this.token = token
    this.gameId = gameId
    this.localVideoEl = localVideoEl
    this.remoteVideoEl = remoteVideoEl
    this.canvasEl = canvasEl
    this.onStatusChange = onStatusChange || (() => { })
    this.onRemoteMediaStatus = onRemoteMediaStatus || (() => { })

    this.socket = null
    this.channel = null
    this.peerConnection = null
    this.localStream = null
    this.animFrameId = null
    this.cameraEnabled = true
    this.micEnabled = true
    this._status = null

    // Transformed stream for sending zoom/rotation to peer
    this._streamForPeer = null
    this._localCanvasEl = null
    this._localAnimFrameId = null
    this._canvasStream = null
  }

  async start() {
    this._setStatus("connecting")

    // Capture local media first so tracks are ready before signaling
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 3840 }, height: { ideal: 2160 } },
        audio: true,
      })
      this.localVideoEl.srcObject = this.localStream
      await this.localVideoEl.play().catch(() => { })
      this._streamForPeer = this._createTransformedStream()
    } catch (err) {
      console.error("[WebRTC] Failed to get user media:", err)
      this._setStatus("no_camera")
    }

    // Connect the Phoenix socket
    this.socket = new Socket("/socket", { params: { token: this.token } })
    this.socket.connect()

    // Join the game channel
    this.channel = this.socket.channel(`game:${this.gameId}`, {})

    this.channel.on("peer_joined", () => this._createOffer())
    this.channel.on("peer_exists", () => console.log("[WebRTC] Peer already in channel, waiting for offer"))
    this.channel.on("offer", (msg) => this._handleOffer(msg))
    this.channel.on("answer", (msg) => this._handleAnswer(msg))
    this.channel.on("ice_candidate", (msg) => this._handleIceCandidate(msg))
    this.channel.on("peer_left", () => this._handlePeerLeft())
    this.channel.on("media_status", (msg) => this.onRemoteMediaStatus(msg))

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

  toggleCamera() {
    if (!this.localStream) return false
    const videoTrack = this.localStream.getVideoTracks()[0]
    if (videoTrack) {
      this.cameraEnabled = !this.cameraEnabled
      videoTrack.enabled = this.cameraEnabled
      if (this._canvasStream) {
        this._canvasStream.getVideoTracks().forEach(t => t.enabled = this.cameraEnabled)
      }
    }
    this._broadcastMediaStatus()
    return this.cameraEnabled
  }

  toggleMic() {
    if (!this.localStream) return false
    const audioTrack = this.localStream.getAudioTracks()[0]
    if (audioTrack) {
      this.micEnabled = !this.micEnabled
      audioTrack.enabled = this.micEnabled
    }
    this._broadcastMediaStatus()
    return this.micEnabled
  }

  async setExternalVideoSource(stream) {
    this._externalStream = stream

    // Update local preview to show the external source
    this.localVideoEl.srcObject = stream
    this.localVideoEl.play().catch(() => { })

    // Rebuild the transformed stream from the new source
    this._stopLocalTransform()
    this._streamForPeer = this._createTransformedStream()

    // Replace the video track on the peer connection
    if (this.peerConnection) {
      const newVideoTrack = this._streamForPeer.getVideoTracks()[0]
      const sender = this.peerConnection
        .getSenders()
        .find((s) => s.track?.kind === "video")
      if (sender && newVideoTrack) {
        await sender.replaceTrack(newVideoTrack)
      }
    }
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

    // Replace the video track back to the webcam
    if (this.peerConnection) {
      const newVideoTrack = this._streamForPeer.getVideoTracks()[0]
      const sender = this.peerConnection
        .getSenders()
        .find((s) => s.track?.kind === "video")
      if (sender && newVideoTrack) {
        await sender.replaceTrack(newVideoTrack)
      }
    }
  }

  _stopLocalTransform() {
    if (this._localAnimFrameId) {
      cancelAnimationFrame(this._localAnimFrameId)
      this._localAnimFrameId = null
    }
    if (this._canvasStream) {
      this._canvasStream.getTracks().forEach((t) => t.stop())
      this._canvasStream = null
    }
    this._localCanvasEl = null
  }

  _broadcastMediaStatus() {
    if (this.channel) {
      this.channel.push("media_status", {
        camera: this.cameraEnabled,
        mic: this.micEnabled,
      })
    }
  }

  disconnect() {
    if (this._localAnimFrameId) {
      cancelAnimationFrame(this._localAnimFrameId)
      this._localAnimFrameId = null
    }

    if (this._canvasStream) {
      this._canvasStream.getTracks().forEach(t => t.stop())
      this._canvasStream = null
    }

    this._localCanvasEl = null
    this._streamForPeer = null

    if (this.animFrameId) {
      cancelAnimationFrame(this.animFrameId)
      this.animFrameId = null
    }

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

  // -- Private methods --

  _setStatus(status) {
    this._status = status
    this.onStatusChange(status)
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
        this.channel.push("ice_candidate", { candidate: event.candidate })
      }
    }

    // When we receive remote tracks
    this.peerConnection.ontrack = (event) => {
      this.remoteVideoEl.srcObject = event.streams[0]
      this.remoteVideoEl.play().catch(() => { })
      this._startCanvasRender()
      this._setStatus("connected")
    }

    this.peerConnection.oniceconnectionstatechange = () => {
      const state = this.peerConnection?.iceConnectionState
      console.log("[WebRTC] ICE connection state:", state)

      if (state === "disconnected" || state === "failed") {
        this._setStatus("disconnected")
        this._stopCanvasRender()
      } else if (state === "connected" || state === "completed") {
        this._setStatus("connected")
      }
    }
  }

  async _createOffer() {
    console.log("[WebRTC] Creating offer (peer joined)")
    this._createPeerConnection()

    const offer = await this.peerConnection.createOffer()
    await this.peerConnection.setLocalDescription(offer)

    this.channel.push("offer", { sdp: this.peerConnection.localDescription })
  }

  async _handleOffer({ sdp }) {
    console.log("[WebRTC] Received offer, creating answer")
    this._createPeerConnection()

    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(sdp))

    const answer = await this.peerConnection.createAnswer()
    await this.peerConnection.setLocalDescription(answer)

    this.channel.push("answer", { sdp: this.peerConnection.localDescription })
  }

  async _handleAnswer({ sdp }) {
    console.log("[WebRTC] Received answer")
    if (this.peerConnection) {
      await this.peerConnection.setRemoteDescription(new RTCSessionDescription(sdp))
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

  _handlePeerLeft() {
    console.log("[WebRTC] Peer left")
    this._stopCanvasRender()

    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }

    this.remoteVideoEl.srcObject = null
    this._clearCanvas()
    this._setStatus("waiting")
  }

  _createTransformedStream() {
    const sourceStream = this._externalStream || this.localStream
    if (!sourceStream) return null

    const zoom = parseFloat(localStorage.getItem("tabletop:camera-zoom") || "1")
    const rotation = parseFloat(localStorage.getItem("tabletop:camera-rotation") || "0")

    // No transforms needed — use raw stream directly
    if (zoom === 1 && rotation === 0) {
      return sourceStream
    }

    // Create a hidden canvas to render transformed video
    this._localCanvasEl = document.createElement("canvas")
    const videoTrack = sourceStream.getVideoTracks()[0]
    const settings = videoTrack.getSettings()
    this._localCanvasEl.width = settings.width || 1280
    this._localCanvasEl.height = settings.height || 720

    const ctx = this._localCanvasEl.getContext("2d")
    const videoEl = this.localVideoEl
    const rad = rotation * Math.PI / 180

    const renderLocal = () => {
      if (videoEl.readyState >= videoEl.HAVE_CURRENT_DATA) {
        const cw = this._localCanvasEl.width
        const ch = this._localCanvasEl.height
        const vw = videoEl.videoWidth
        const vh = videoEl.videoHeight

        // Zoom: crop source rectangle from center
        const sw = vw / zoom
        const sh = vh / zoom
        const sx = (vw - sw) / 2
        const sy = (vh - sh) / 2

        // Scale up to fill corners when rotated
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
      this._localAnimFrameId = requestAnimationFrame(renderLocal)
    }
    this._localAnimFrameId = requestAnimationFrame(renderLocal)

    // Capture stream from canvas at 30fps
    this._canvasStream = this._localCanvasEl.captureStream(30)

    // Combine canvas video track with audio tracks from the active source
    const combinedStream = new MediaStream()
    this._canvasStream.getVideoTracks().forEach(t => combinedStream.addTrack(t))
    sourceStream.getAudioTracks().forEach(t => combinedStream.addTrack(t))

    return combinedStream
  }

  _startCanvasRender() {
    if (this.animFrameId) return

    const ctx = this.canvasEl.getContext("2d")

    const render = () => {
      if (this.remoteVideoEl.readyState >= this.remoteVideoEl.HAVE_CURRENT_DATA) {
        const vw = this.remoteVideoEl.videoWidth
        const vh = this.remoteVideoEl.videoHeight
        const container = this.canvasEl.parentElement
        const containerW = container.clientWidth
        const containerH = container.clientHeight

        // Fit canvas to container while preserving video aspect ratio
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

        this.canvasEl.style.width = displayW + "px"
        this.canvasEl.style.height = displayH + "px"

        // Set buffer to native video resolution for sharp OCR captures
        if (this.canvasEl.width !== vw || this.canvasEl.height !== vh) {
          this.canvasEl.width = vw
          this.canvasEl.height = vh
        }

        ctx.drawImage(this.remoteVideoEl, 0, 0, vw, vh)
      }
      this.animFrameId = requestAnimationFrame(render)
    }

    this.animFrameId = requestAnimationFrame(render)
  }

  _stopCanvasRender() {
    if (this.animFrameId) {
      cancelAnimationFrame(this.animFrameId)
      this.animFrameId = null
    }
  }

  _clearCanvas() {
    const ctx = this.canvasEl.getContext("2d")
    ctx.clearRect(0, 0, this.canvasEl.width, this.canvasEl.height)
    this.canvasEl.style.width = ""
    this.canvasEl.style.height = ""
  }
}
