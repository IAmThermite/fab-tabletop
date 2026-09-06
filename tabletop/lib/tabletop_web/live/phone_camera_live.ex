defmodule TabletopWeb.PhoneCameraLive do
  use TabletopWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} system_announcement={@system_announcement}>
      <div
        :if={@valid}
        id="phone-camera"
        phx-hook=".PhoneCamera"
        data-relay-token={@token}
        data-relay-user-id={@relay_user_id}
        data-ice-servers={Jason.encode!(@ice_servers)}
        class="flex flex-col h-full"
      >
        <%!-- Top bar --%>
        <div class="flex items-center gap-3 px-3 py-2 bg-base-200 border-b border-base-300">
          <div class="flex-1 text-center font-semibold truncate">
            Phone Camera
          </div>

          <div
            id="phone-status"
            phx-update="ignore"
            class="badge badge-sm badge-outline cursor-pointer"
          >
            Connecting...
          </div>

          <Layouts.game_alert_tray flash={@flash} system_announcement={@system_announcement} />
        </div>

        <%!-- Camera preview --%>
        <div class="flex-1 relative bg-black min-h-0">
          <video
            id="phone-video"
            autoplay
            muted
            playsinline
            class="w-full h-full object-cover"
          >
          </video>

          <%!-- Outbound video diagnostics, opt-in. A phone has no console within
               reach, so the numbers go on the glass. JS owns the content, hence
               phx-update="ignore". --%>
          <div
            id="phone-debug"
            phx-update="ignore"
            class="absolute top-2 left-2 right-2 hidden rounded bg-black/70 px-2 py-1 font-mono text-[11px] leading-tight text-white"
          >
          </div>

          <%!-- No camera overlay --%>
          <div
            id="phone-no-camera"
            class="absolute inset-0 flex items-center justify-center bg-base-300 hidden"
          >
            <div class="text-center">
              <.icon name="hero-video-camera-slash" class="size-16 mx-auto mb-3 opacity-50" />
              <p class="text-lg opacity-75">Camera not available</p>
              <p class="text-sm opacity-50 mt-1">Check your browser permissions</p>
            </div>
          </div>
        </div>

        <%!-- Bottom controls --%>
        <div class="flex items-center justify-center gap-4 px-4 py-3 bg-base-200 border-t border-base-300">
          <button
            id="phone-flip-camera"
            type="button"
            class="btn btn-circle btn-sm"
            title="Switch camera"
          >
            <.icon name="hero-arrow-path" class="size-5" />
          </button>
        </div>
      </div>

      <div :if={!@valid} class="flex items-center justify-center h-full">
        <div class="text-center p-8">
          <.icon name="hero-exclamation-triangle" class="size-16 mx-auto mb-4 text-error" />
          <h2 class="text-xl font-bold mb-2">Invalid or Expired Link</h2>
          <p class="opacity-75">
            This camera link has expired or is invalid.
            Please scan a new QR code from the game settings.
          </p>
        </div>
      </div>
    </Layouts.game>

    <script :type={ColocatedHook} name=".PhoneCamera">
      import PhoneCameraRelay from "@/js/phone_camera_relay.js"
      import { startVideoFrameLoop } from "@/js/video_frame_loop.js"
      import { TARGET_FRAMERATE, hintVideoDetail } from "@/js/webrtc_tuning.js"

      export default {
        mounted() {
          const relayToken = this.el.dataset.relayToken
          const relayUserId = this.el.dataset.relayUserId
          const iceServers = JSON.parse(this.el.dataset.iceServers)
          const videoEl = document.getElementById("phone-video")
          const noCameraEl = document.getElementById("phone-no-camera")
          const statusEl = document.getElementById("phone-status")
          const flipBtn = document.getElementById("phone-flip-camera")
          const debugEl = document.getElementById("phone-debug")

          let currentFacingMode = "environment"
          let stream = null
          let canvasStream = null
          let stopRotationLoop = null
          let rotateHiddenVideo = null

          // Try to lock to landscape (works in some browsers when fullscreen)
          screen.orientation?.lock("landscape").catch(() => {})

          this.relay = new PhoneCameraRelay({
            relayToken,
            relayUserId,
            iceServers,
            onStatusChange: (status) => {
              const labels = {
                connecting: "Connecting...",
                waiting: "Waiting for desktop...",
                connected: "Connected",
                disconnected: "Disconnected",
                superseded: "Open in another tab",
                error: "Error",
              }
              statusEl.textContent = labels[status] || status

              const badgeClass = {
                connected: "badge-success",
                disconnected: "badge-error",
                error: "badge-error",
                superseded: "badge-warning",
              }
              statusEl.className = `badge badge-sm cursor-pointer ${badgeClass[status] || "badge-outline"}`
            },
            onStats: (stats) => {
              debugEl.textContent =
                `${stats.width ?? "?"}x${stats.height ?? "?"} ` +
                `@${stats.fps ?? "?"}fps ${stats.codec || "?"} ` +
                `${stats.targetKbps ?? "?"}kbps limited=${stats.limitation ?? "?"}`
            },
          })

          // Outbound video diagnostics. `limited=` is the field that decides
          // where to look: "cpu" means the encoder is starved — the phone's
          // usual failure — "bandwidth" blames the link, and "none" at a low
          // resolution means MAX_VIDEO_BITRATE is the ceiling.
          //
          // Three ways in, because the two the desktop uses are impractical
          // here: ?debug=1 needs a long tokenised URL retyped on a phone
          // keyboard, and the localStorage flag needs devtools attached. So
          // tapping the status badge toggles it too, which is the one that
          // works with nothing but the phone in your hand.
          const setDebugVisible = (visible) => {
            debugEl.classList.toggle("hidden", !visible)
            if (visible) {
              this.relay.startStatsLogging()
            } else {
              this.relay.stopStatsLogging()
              debugEl.textContent = ""
            }
          }

          statusEl.title = "Tap for video diagnostics"
          statusEl.addEventListener("click", () => {
            setDebugVisible(debugEl.classList.contains("hidden"))
          })

          if (
            new URLSearchParams(window.location.search).get("debug") === "1" ||
            localStorage.getItem("tabletop:debug-webrtc") === "true"
          ) {
            setDebugVisible(true)
          }

          const getCamera = async (facingMode) => {
            try {
              const newStream = await navigator.mediaDevices.getUserMedia({
                video: {
                  facingMode: { ideal: facingMode },
                  width: { ideal: 1920 },
                  height: { ideal: 1080 },
                  aspectRatio: { ideal: 16 / 9 },
                  frameRate: { ideal: TARGET_FRAMERATE },
                },
                audio: true,
              })
              noCameraEl.classList.add("hidden")
              return newStream
            } catch (err) {
              console.error("[PhoneCamera] Failed to get camera:", err)
              noCameraEl.classList.remove("hidden")
              return null
            }
          }

          // Normalizes the camera into a landscape stream by piping it through
          // an offscreen canvas. The rotation decision is made per-frame from
          // the live videoWidth/videoHeight, so a portrait frame (phone held
          // upright) is rotated 90°, and rotating the phone mid-session is
          // handled automatically. We avoid videoTrack.getSettings() here —
          // it reports the sensor's native landscape dims even when the phone
          // is vertical, which is why portrait video used to slip through.
          const buildOutboundStream = (cameraStream) => {
            const canvas = document.createElement("canvas")
            const ctx = canvas.getContext("2d")
            canvas.width = 1920
            canvas.height = 1080

            rotateHiddenVideo = document.createElement("video")
            rotateHiddenVideo.muted = true
            rotateHiddenVideo.playsInline = true
            rotateHiddenVideo.srcObject = cameraStream
            rotateHiddenVideo.play().catch(() => {})

            const render = () => {
              const v = rotateHiddenVideo
              if (!v) return
              const vw = v.videoWidth
              const vh = v.videoHeight
              if (vw <= 0 || vh <= 0) return

              const isPortrait = vh > vw
              // Output is always landscape; swap dims when rotating.
              const outW = isPortrait ? vh : vw
              const outH = isPortrait ? vw : vh
              if (canvas.width !== outW || canvas.height !== outH) {
                canvas.width = outW
                canvas.height = outH
              }
              ctx.save()
              if (isPortrait) {
                ctx.translate(outW / 2, outH / 2)
                ctx.rotate(-Math.PI / 2)
                ctx.drawImage(v, -vw / 2, -vh / 2, vw, vh)
              } else {
                ctx.drawImage(v, 0, 0, outW, outH)
              }
              ctx.restore()
            }
            // Keyed to the camera's frame clock rather than the display's: a
            // phone screen refreshes at 60-120Hz, so a plain rAF loop would
            // redraw each 30fps frame two to four times over — on the same
            // battery-powered CPU that has to encode 1080p at the same moment.
            stopRotationLoop = startVideoFrameLoop(rotateHiddenVideo, render)

            // Capture the canvas as a video stream, carry audio from the original.
            const out = canvas.captureStream(TARGET_FRAMERATE)
            const audioTrack = cameraStream.getAudioTracks()[0]
            if (audioTrack) {
              out.addTrack(audioTrack)
            }
            hintVideoDetail(out)
            return out
          }

          const stopRotationPipeline = () => {
            if (stopRotationLoop) {
              stopRotationLoop()
              stopRotationLoop = null
            }
            if (rotateHiddenVideo) {
              rotateHiddenVideo.srcObject = null
              rotateHiddenVideo = null
            }
          }

          const start = async () => {
            stream = await getCamera(currentFacingMode)
            if (!stream) return

            videoEl.srcObject = stream
            canvasStream = buildOutboundStream(stream)
            this.relay.start(canvasStream)
          }

          // Flip camera (front/back)
          flipBtn.addEventListener("click", async () => {
            currentFacingMode = currentFacingMode === "environment" ? "user" : "environment"
            stopRotationPipeline()
            const newStream = await getCamera(currentFacingMode)
            if (newStream) {
              stream = newStream
              videoEl.srcObject = stream
              canvasStream = buildOutboundStream(stream)
              this.relay.replaceStream(canvasStream)
            }
          })

          // Handle phone sleep/background — re-acquire camera on visibility change
          this._visibilityHandler = async () => {
            if (document.visibilityState === "visible" && stream) {
              // Check if the video track is still live
              const videoTrack = stream.getVideoTracks()[0]
              if (!videoTrack || videoTrack.readyState === "ended") {
                console.log("[PhoneCamera] Track ended, re-acquiring camera")
                stopRotationPipeline()
                const newStream = await getCamera(currentFacingMode)
                if (newStream) {
                  stream = newStream
                  videoEl.srcObject = stream
                  canvasStream = buildOutboundStream(stream)
                  this.relay.replaceStream(canvasStream)
                }
              }
            }
          }
          document.addEventListener("visibilitychange", this._visibilityHandler)

          start()

          this._cleanup = () => {
            document.removeEventListener("visibilitychange", this._visibilityHandler)
            stopRotationPipeline()
            screen.orientation?.unlock?.()
            if (this.relay) this.relay.disconnect()
            if (stream) stream.getTracks().forEach(t => t.stop())
          }
        },

        destroyed() {
          if (this._cleanup) this._cleanup()
        },
      }
    </script>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {valid, relay_user_id} =
      case TabletopWeb.CameraRelayToken.verify(TabletopWeb.Endpoint, token) do
        {:ok, user_id} -> {true, user_id}
        {:error, _} -> {false, nil}
      end

    {:ok,
     socket
     |> assign(:page_title, "Phone Camera")
     |> assign(:token, token)
     |> assign(:relay_user_id, relay_user_id)
     |> assign(:ice_servers, Tabletop.Turn.ice_servers(relay_user_id))
     |> assign(:valid, valid)}
  end
end
