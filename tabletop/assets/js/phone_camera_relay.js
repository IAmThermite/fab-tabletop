// Phone Camera Relay — sends the phone's camera stream to the desktop via WebRTC
//
// Used on the phone-side page (/phone-camera/:token). Connects to the
// camera_relay:{token} Phoenix channel for signaling, then establishes a
// one-way WebRTC connection to send video to the desktop.

import { Socket } from "phoenix"
import { hintVideoDetail, preferVideoCodecs, tuneVideoSender } from "./webrtc_tuning"

const ICE_SERVERS = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun1.l.google.com:19302" },
]

export default class PhoneCameraRelay {
  constructor({ relayToken, relayUserId, onStatusChange }) {
    this.relayToken = relayToken
    this.relayUserId = relayUserId
    this.onStatusChange = onStatusChange || (() => {})

    this.socket = null
    this.channel = null
    this.peerConnection = null
    this.localStream = null
    this._status = null
    // Set when a newer phone socket takes this user's relay seat (see
    // TabletopWeb.ChannelSeat) — the QR scanned twice, or the page reopened.
    // Terminal: this page does not signal again.
    this._superseded = false
  }

  async start(stream) {
    this.localStream = stream
    // This hop is the *first* of two lossy generations — the desktop decodes
    // this stream and re-encodes it for the opponent — so detail lost here is
    // gone for good. Tune it exactly like the game link.
    hintVideoDetail(stream)
    this._setStatus("connecting")

    this.socket = new Socket("/socket", {
      params: { camera_relay_token: this.relayToken },
    })
    this.socket.connect()

    // Topic is keyed by user_id (stable), while the signed token above is
    // only used to authenticate the socket connection.
    this.channel = this.socket.channel(`camera_relay:${this.relayUserId}`, {})

    this.channel.on("peer_joined", () => this._createOffer())
    this.channel.on("peer_exists", () => {
      console.log("[PhoneRelay] Desktop already connected, waiting for offer")
    })
    this.channel.on("offer", (msg) => this._handleOffer(msg))
    this.channel.on("answer", (msg) => this._handleAnswer(msg))
    this.channel.on("ice_candidate", (msg) => this._handleIceCandidate(msg))
    this.channel.on("peer_left", () => this._handlePeerLeft())
    this.channel.on("superseded", () => this._handleSuperseded())

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
    hintVideoDetail(newStream)

    if (this.peerConnection) {
      const newVideoTrack = newStream.getVideoTracks()[0]
      const sender = this.peerConnection
        .getSenders()
        .find((s) => s.track?.kind === "video")
      if (sender && newVideoTrack) {
        await sender.replaceTrack(newVideoTrack)
        // A fresh track can arrive with default encodings.
        await tuneVideoSender(this.peerConnection)
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
        this._push("ice_candidate", { candidate: event.candidate })
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

  // Signalling is emitted from async paths that can resume after the channel is
  // gone, so this never throws on a torn-down channel.
  _push(event, payload) {
    if (!this.channel) return
    this.channel.push(event, payload)
  }

  async _createOffer() {
    if (this._superseded) return

    try {
      console.log("[PhoneRelay] Creating offer")
      this._createPeerConnection()
      preferVideoCodecs(this.peerConnection)

      const offer = await this.peerConnection.createOffer()
      await this.peerConnection.setLocalDescription(offer)
      this._push("offer", { sdp: this.peerConnection.localDescription })
      await tuneVideoSender(this.peerConnection)
    } catch (err) {
      console.error("[PhoneRelay] Error creating offer:", err)
      this._setStatus("error")
    }
  }

  async _handleOffer({ sdp }) {
    if (this._superseded) return

    try {
      console.log("[PhoneRelay] Received offer, creating answer")
      this._createPeerConnection()

      await this.peerConnection.setRemoteDescription(
        new RTCSessionDescription(sdp)
      )
      preferVideoCodecs(this.peerConnection)

      const answer = await this.peerConnection.createAnswer()
      await this.peerConnection.setLocalDescription(answer)
      this._push("answer", { sdp: this.peerConnection.localDescription })
      await tuneVideoSender(this.peerConnection)
    } catch (err) {
      console.error("[PhoneRelay] Error handling offer:", err)
      this._setStatus("error")
    }
  }

  async _handleAnswer({ sdp }) {
    try {
      console.log("[PhoneRelay] Received answer")
      if (this.peerConnection) {
        await this.peerConnection.setRemoteDescription(
          new RTCSessionDescription(sdp)
        )
        await tuneVideoSender(this.peerConnection)
      }
    } catch (err) {
      console.error("[PhoneRelay] Error handling answer:", err)
      this._setStatus("error")
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

  // A newer phone socket took this user's relay seat — the QR scanned a second
  // time, usually. Only one phone may sit on the relay topic (see
  // TabletopWeb.ChannelSeat), so this page stops relaying and says so rather
  // than fighting the newer one over the desktop's connection.
  _handleSuperseded() {
    console.warn("[PhoneRelay] Superseded — this camera is relaying from a newer tab")
    this._superseded = true

    this.disconnect()
    this._setStatus("superseded")
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
