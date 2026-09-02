// Camera Relay Receiver — receives the phone's camera stream on the desktop
//
// Connects to camera_relay:{token} channel (reusing the existing Phoenix socket)
// and establishes a WebRTC connection to receive video from the phone.

import { Socket } from "phoenix"

// Fallback used only if the server doesn't supply iceServers (STUN-only).
const DEFAULT_ICE_SERVERS = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun1.l.google.com:19302" },
]

export default class CameraRelayReceiver {
  constructor({ token, relayUserId, iceServers, onStream, onDisconnect, onStatusChange }) {
    this.token = token
    this.relayUserId = relayUserId
    this.iceServers = iceServers?.length ? iceServers : DEFAULT_ICE_SERVERS
    this.onStream = onStream || (() => {})
    this.onDisconnect = onDisconnect || (() => {})
    this.onStatusChange = onStatusChange || (() => {})

    this.socket = null
    this.channel = null
    this.peerConnection = null
    this._status = null
    // Set when a newer desktop socket takes this user's relay seat (see
    // TabletopWeb.ChannelSeat). Terminal — this receiver does not signal again.
    this._superseded = false
  }

  start() {
    this._setStatus("waiting")

    // Use a separate socket connection for the relay channel
    // (the main socket is used for the game channel)
    this.socket = new Socket("/socket", { params: { token: this.token } })
    this.socket.connect()

    // Topic is keyed by user_id (stable across page mounts); the socket
    // connection above is authenticated by the user-socket token.
    this.channel = this.socket.channel(`camera_relay:${this.relayUserId}`, {})

    // The server nominates the phone to offer, so in practice this end
    // answers — but the binding stays symmetric, because which end offers is
    // the server's decision to change, not a rule baked in here. See
    // `TabletopWeb.CameraRelayChannel.request_offer/1`.
    this.channel.on("make_offer", () => this._createOffer())
    this.channel.on("peer_joined", () => {
      console.log("[RelayReceiver] Phone joined the relay")
    })
    this.channel.on("peer_exists", () => {
      console.log("[RelayReceiver] Phone already on the relay")
    })
    this.channel.on("offer", (msg) => this._handleOffer(msg))
    this.channel.on("answer", (msg) => this._handleAnswer(msg))
    this.channel.on("ice_candidate", (msg) => this._handleIceCandidate(msg))
    this.channel.on("peer_left", () => this._handlePeerLeft())
    this.channel.on("superseded", () => this._handleSuperseded())

    this.channel
      .join()
      .receive("ok", () => {
        console.log("[RelayReceiver] Joined relay channel")
      })
      .receive("error", (resp) => {
        console.error("[RelayReceiver] Failed to join channel:", resp)
        this._setStatus("error")
      })
  }

  disconnect() {
    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
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

    this.peerConnection = new RTCPeerConnection({ iceServers: this.iceServers })

    this.peerConnection.onicecandidate = (event) => {
      if (event.candidate) {
        this._push("ice_candidate", { candidate: event.candidate })
      }
    }

    // When we receive the phone's video stream
    this.peerConnection.ontrack = (event) => {
      console.log("[RelayReceiver] Received phone stream")
      this._setStatus("connected")
      this.onStream(event.streams[0])
    }

    this.peerConnection.oniceconnectionstatechange = () => {
      const state = this.peerConnection?.iceConnectionState
      console.log("[RelayReceiver] ICE state:", state)

      if (state === "disconnected" || state === "failed") {
        this._setStatus("disconnected")
        this.onDisconnect()
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
      console.log("[RelayReceiver] Creating offer")
      this._createPeerConnection()

      // Add a transceiver to receive video (we don't send anything)
      this.peerConnection.addTransceiver("video", { direction: "recvonly" })
      this.peerConnection.addTransceiver("audio", { direction: "recvonly" })

      const offer = await this.peerConnection.createOffer()
      await this.peerConnection.setLocalDescription(offer)
      this._push("offer", { sdp: this.peerConnection.localDescription })
    } catch (err) {
      console.error("[RelayReceiver] Error creating offer:", err)
      this._setStatus("error")
    }
  }

  async _handleOffer({ sdp }) {
    if (this._superseded) return

    try {
      console.log("[RelayReceiver] Received offer, creating answer")
      this._createPeerConnection()

      await this.peerConnection.setRemoteDescription(
        new RTCSessionDescription(sdp)
      )
      const answer = await this.peerConnection.createAnswer()
      await this.peerConnection.setLocalDescription(answer)
      this._push("answer", { sdp: this.peerConnection.localDescription })
    } catch (err) {
      console.error("[RelayReceiver] Error handling offer:", err)
      this._setStatus("error")
    }
  }

  async _handleAnswer({ sdp }) {
    try {
      console.log("[RelayReceiver] Received answer")
      if (this.peerConnection) {
        await this.peerConnection.setRemoteDescription(
          new RTCSessionDescription(sdp)
        )
      }
    } catch (err) {
      console.error("[RelayReceiver] Error handling answer:", err)
      this._setStatus("error")
    }
  }

  async _handleIceCandidate({ candidate }) {
    if (this.peerConnection && candidate) {
      try {
        await this.peerConnection.addIceCandidate(
          new RTCIceCandidate(candidate)
        )
      } catch (err) {
        console.error("[RelayReceiver] Error adding ICE candidate:", err)
      }
    }
  }

  // A newer desktop socket took this user's relay seat — the same page open in
  // a second tab, or a page that supersedes this one (camera setup, pre-join,
  // the game). Only one desktop may sit on the relay topic (see
  // TabletopWeb.ChannelSeat), so this one stands down and reports the phone as
  // disconnected, which is what it now is *for this tab*.
  _handleSuperseded() {
    console.warn("[RelayReceiver] Superseded — the phone is relaying to a newer tab")
    this._superseded = true

    this.disconnect()
    this._setStatus("superseded")
    this.onDisconnect()
  }

  _handlePeerLeft() {
    console.log("[RelayReceiver] Phone disconnected")
    if (this.peerConnection) {
      this.peerConnection.close()
      this.peerConnection = null
    }
    this._setStatus("disconnected")
    this.onDisconnect()
  }
}
