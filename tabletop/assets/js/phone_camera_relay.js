// Phone Camera Relay — sends the phone's camera stream to the desktop via WebRTC
//
// Used on the phone-side page (/phone-camera/:token). Connects to the
// camera_relay:{token} Phoenix channel for signaling, then establishes a
// one-way WebRTC connection to send video to the desktop.

import { Socket } from "phoenix"

const ICE_SERVERS = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun1.l.google.com:19302" },
]

export default class PhoneCameraRelay {
  constructor({ relayToken, onStatusChange }) {
    this.relayToken = relayToken
    this.onStatusChange = onStatusChange || (() => {})

    this.socket = null
    this.channel = null
    this.peerConnection = null
    this.localStream = null
    this._status = null
  }

  async start(stream) {
    this.localStream = stream
    this._setStatus("connecting")

    this.socket = new Socket("/socket", {
      params: { camera_relay_token: this.relayToken },
    })
    this.socket.connect()

    this.channel = this.socket.channel(`camera_relay:${this.relayToken}`, {})

    this.channel.on("peer_joined", () => this._createOffer())
    this.channel.on("peer_exists", () => {
      console.log("[PhoneRelay] Desktop already connected, waiting for offer")
    })
    this.channel.on("offer", (msg) => this._handleOffer(msg))
    this.channel.on("answer", (msg) => this._handleAnswer(msg))
    this.channel.on("ice_candidate", (msg) => this._handleIceCandidate(msg))
    this.channel.on("peer_left", () => this._handlePeerLeft())

    this.channel
      .join()
      .receive("ok", () => {
        console.log("[PhoneRelay] Joined relay channel")
        if (this._status !== "connected") {
          this._setStatus("waiting")
        }
      })
      .receive("error", (resp) => {
        console.error("[PhoneRelay] Failed to join channel:", resp)
        this._setStatus("error")
      })
  }

  async replaceStream(newStream) {
    const oldStream = this.localStream
    this.localStream = newStream

    if (this.peerConnection) {
      const newVideoTrack = newStream.getVideoTracks()[0]
      const sender = this.peerConnection
        .getSenders()
        .find((s) => s.track?.kind === "video")
      if (sender && newVideoTrack) {
        await sender.replaceTrack(newVideoTrack)
      }

      const newAudioTrack = newStream.getAudioTracks()[0]
      const audioSender = this.peerConnection
        .getSenders()
        .find((s) => s.track?.kind === "audio")
      if (audioSender && newAudioTrack) {
        await audioSender.replaceTrack(newAudioTrack)
      }
    }

    // Stop old tracks
    if (oldStream) {
      oldStream.getTracks().forEach((t) => t.stop())
    }
  }

  disconnect() {
    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }

    if (this.localStream) {
      this.localStream.getTracks().forEach((t) => t.stop())
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

  // -- Private --

  _setStatus(status) {
    this._status = status
    this.onStatusChange(status)
  }

  _createPeerConnection() {
    if (this.peerConnection) {
      this.peerConnection.close()
    }

    this.peerConnection = new RTCPeerConnection({ iceServers: ICE_SERVERS })

    if (this.localStream) {
      this.localStream.getTracks().forEach((track) => {
        this.peerConnection.addTrack(track, this.localStream)
      })
    }

    this.peerConnection.onicecandidate = (event) => {
      if (event.candidate) {
        this.channel.push("ice_candidate", { candidate: event.candidate })
      }
    }

    this.peerConnection.oniceconnectionstatechange = () => {
      const state = this.peerConnection?.iceConnectionState
      console.log("[PhoneRelay] ICE state:", state)

      if (state === "disconnected" || state === "failed") {
        this._setStatus("disconnected")
      } else if (state === "connected" || state === "completed") {
        this._setStatus("connected")
      }
    }
  }

  async _createOffer() {
    console.log("[PhoneRelay] Creating offer")
    this._createPeerConnection()

    const offer = await this.peerConnection.createOffer()
    await this.peerConnection.setLocalDescription(offer)
    this.channel.push("offer", { sdp: this.peerConnection.localDescription })
  }

  async _handleOffer({ sdp }) {
    console.log("[PhoneRelay] Received offer, creating answer")
    this._createPeerConnection()

    await this.peerConnection.setRemoteDescription(
      new RTCSessionDescription(sdp)
    )
    const answer = await this.peerConnection.createAnswer()
    await this.peerConnection.setLocalDescription(answer)
    this.channel.push("answer", { sdp: this.peerConnection.localDescription })
  }

  async _handleAnswer({ sdp }) {
    console.log("[PhoneRelay] Received answer")
    if (this.peerConnection) {
      await this.peerConnection.setRemoteDescription(
        new RTCSessionDescription(sdp)
      )
    }
  }

  async _handleIceCandidate({ candidate }) {
    if (this.peerConnection && candidate) {
      try {
        await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
      } catch (err) {
        console.error("[PhoneRelay] Error adding ICE candidate:", err)
      }
    }
  }

  _handlePeerLeft() {
    console.log("[PhoneRelay] Desktop disconnected")
    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }
    this._setStatus("waiting")
  }
}
