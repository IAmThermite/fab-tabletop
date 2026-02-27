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
    this.onStatusChange = onStatusChange || (() => {})
    this.onRemoteMediaStatus = onRemoteMediaStatus || (() => {})

    this.socket = null
    this.channel = null
    this.peerConnection = null
    this.localStream = null
    this.animFrameId = null
    this.cameraEnabled = true
    this.micEnabled = true
    this._status = null
  }

  async start() {
    this._setStatus("connecting")

    // Capture local media first so tracks are ready before signaling
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: true,
      })
      this.localVideoEl.srcObject = this.localStream
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

  _broadcastMediaStatus() {
    if (this.channel) {
      this.channel.push("media_status", {
        camera: this.cameraEnabled,
        mic: this.micEnabled,
      })
    }
  }

  disconnect() {
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

    // Add local tracks to the connection
    if (this.localStream) {
      this.localStream.getTracks().forEach((track) => {
        this.peerConnection.addTrack(track, this.localStream)
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
      this.remoteVideoEl.play().catch(() => {})
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

  _startCanvasRender() {
    if (this.animFrameId) return

    const ctx = this.canvasEl.getContext("2d")

    const render = () => {
      if (this.remoteVideoEl.readyState >= this.remoteVideoEl.HAVE_CURRENT_DATA) {
        const cw = this.canvasEl.clientWidth
        const ch = this.canvasEl.clientHeight
        this.canvasEl.width = cw
        this.canvasEl.height = ch

        const vw = this.remoteVideoEl.videoWidth
        const vh = this.remoteVideoEl.videoHeight
        const scale = Math.min(cw / vw, ch / vh)
        const dw = vw * scale
        const dh = vh * scale
        const dx = (cw - dw) / 2
        const dy = (ch - dh) / 2

        ctx.clearRect(0, 0, cw, ch)
        ctx.drawImage(this.remoteVideoEl, dx, dy, dw, dh)
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
  }
}
