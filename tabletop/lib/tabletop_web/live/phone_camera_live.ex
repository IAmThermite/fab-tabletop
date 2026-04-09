defmodule TabletopWeb.PhoneCameraLive do
  use TabletopWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash}>
      <div
        :if={@valid}
        id="phone-camera"
        phx-hook=".PhoneCamera"
        data-relay-token={@token}
        class="flex flex-col h-full"
      >
        <%!-- Top bar --%>
        <div class="flex items-center gap-3 px-3 py-2 bg-base-200 border-b border-base-300">
          <div class="flex-1 text-center font-semibold truncate">
            Phone Camera
          </div>

          <div id="phone-status" phx-update="ignore" class="badge badge-sm badge-outline">
            Connecting...
          </div>
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

          <div class="flex items-center gap-2">
            <span class="text-xs font-semibold">Zoom</span>
            <input
              id="phone-zoom-slider"
              type="range"
              min="1"
              max="3"
              step="0.1"
              value="1"
              class="range range-xs range-primary w-32"
            />
            <span id="phone-zoom-value" class="text-xs w-8">1.0x</span>
          </div>
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

      export default {
        mounted() {
          const relayToken = this.el.dataset.relayToken
          const videoEl = document.getElementById("phone-video")
          const noCameraEl = document.getElementById("phone-no-camera")
          const statusEl = document.getElementById("phone-status")
          const flipBtn = document.getElementById("phone-flip-camera")
          const zoomSlider = document.getElementById("phone-zoom-slider")
          const zoomValueEl = document.getElementById("phone-zoom-value")

          let currentFacingMode = "environment"
          let stream = null
          let canvasStream = null
          let animFrameId = null

          // Offscreen canvas used to rotate portrait video into landscape
          const rotateCanvas = document.createElement("canvas")
          const rotateCtx = rotateCanvas.getContext("2d")

          // Try to lock to landscape (works in some browsers when fullscreen)
          screen.orientation?.lock("landscape").catch(() => {})

          this.relay = new PhoneCameraRelay({
            relayToken,
            onStatusChange: (status) => {
              const labels = {
                connecting: "Connecting...",
                waiting: "Waiting for desktop...",
                connected: "Connected",
                disconnected: "Disconnected",
                error: "Error",
              }
              statusEl.textContent = labels[status] || status

              const badgeClass = {
                connected: "badge-success",
                disconnected: "badge-error",
                error: "badge-error",
              }
              statusEl.className = `badge badge-sm ${badgeClass[status] || "badge-outline"}`
            },
          })

          const getCamera = async (facingMode) => {
            try {
              const newStream = await navigator.mediaDevices.getUserMedia({
                video: {
                  facingMode: { ideal: facingMode },
                  width: { ideal: 1920 },
                  height: { ideal: 1080 },
                  aspectRatio: { ideal: 16 / 9 },
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

          // Creates a landscape stream from the camera.
          // If the video is portrait (phone held upright), we rotate it 90°
          // via an offscreen canvas and capture that instead.
          const createLandscapeStream = (cameraStream) => {
            const videoTrack = cameraStream.getVideoTracks()[0]
            if (!videoTrack) return cameraStream

            const settings = videoTrack.getSettings()
            const isPortrait = settings.height > settings.width

            if (!isPortrait) {
              // Already landscape, send raw stream
              return cameraStream
            }

            // Portrait mode: rotate via canvas
            // Swapped dimensions so output is landscape
            rotateCanvas.width = settings.height
            rotateCanvas.height = settings.width

            // Hidden video element to drive canvas rendering
            const hiddenVideo = document.createElement("video")
            hiddenVideo.srcObject = cameraStream
            hiddenVideo.muted = true
            hiddenVideo.playsInline = true
            hiddenVideo.play().catch(() => {})

            // Render loop: draw rotated frame
            const renderRotated = () => {
              if (hiddenVideo.readyState >= hiddenVideo.HAVE_CURRENT_DATA) {
                const vw = hiddenVideo.videoWidth
                const vh = hiddenVideo.videoHeight
                // Output canvas is vh x vw (landscape)
                rotateCanvas.width = vh
                rotateCanvas.height = vw

                rotateCtx.save()
                rotateCtx.translate(rotateCanvas.width / 2, rotateCanvas.height / 2)
                rotateCtx.rotate(-Math.PI / 2)
                rotateCtx.drawImage(hiddenVideo, -vw / 2, -vh / 2, vw, vh)
                rotateCtx.restore()
              }
              animFrameId = requestAnimationFrame(renderRotated)
            }
            animFrameId = requestAnimationFrame(renderRotated)

            // Capture the canvas as a video stream, add audio from the original
            const rotatedStream = rotateCanvas.captureStream(30)
            const audioTrack = cameraStream.getAudioTracks()[0]
            if (audioTrack) {
              rotatedStream.addTrack(audioTrack)
            }

            // Store reference so we can clean up
            this._hiddenVideo = hiddenVideo

            return rotatedStream
          }

          const stopCanvasStream = () => {
            if (animFrameId) {
              cancelAnimationFrame(animFrameId)
              animFrameId = null
            }
            if (this._hiddenVideo) {
              this._hiddenVideo.srcObject = null
              this._hiddenVideo = null
            }
          }

          const start = async () => {
            stream = await getCamera(currentFacingMode)
            if (!stream) return

            videoEl.srcObject = stream
            canvasStream = createLandscapeStream(stream)
            this.relay.start(canvasStream)
          }

          // Flip camera (front/back)
          flipBtn.addEventListener("click", async () => {
            currentFacingMode = currentFacingMode === "environment" ? "user" : "environment"
            stopCanvasStream()
            const newStream = await getCamera(currentFacingMode)
            if (newStream) {
              stream = newStream
              videoEl.srcObject = stream
              canvasStream = createLandscapeStream(stream)
              this.relay.replaceStream(canvasStream)
            }
          })

          // Zoom slider
          zoomSlider.addEventListener("input", () => {
            const zoom = parseFloat(zoomSlider.value)
            zoomValueEl.textContent = zoom.toFixed(1) + "x"

            // Apply zoom via CSS transform on the video element
            videoEl.style.transform = `scale(${zoom})`
          })

          // Handle phone sleep/background — re-acquire camera on visibility change
          this._visibilityHandler = async () => {
            if (document.visibilityState === "visible" && stream) {
              // Check if the video track is still live
              const videoTrack = stream.getVideoTracks()[0]
              if (!videoTrack || videoTrack.readyState === "ended") {
                console.log("[PhoneCamera] Track ended, re-acquiring camera")
                stopCanvasStream()
                const newStream = await getCamera(currentFacingMode)
                if (newStream) {
                  stream = newStream
                  videoEl.srcObject = stream
                  canvasStream = createLandscapeStream(stream)
                  this.relay.replaceStream(canvasStream)
                }
              }
            }
          }
          document.addEventListener("visibilitychange", this._visibilityHandler)

          start()

          this._cleanup = () => {
            document.removeEventListener("visibilitychange", this._visibilityHandler)
            stopCanvasStream()
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
    valid =
      case Phoenix.Token.verify(TabletopWeb.Endpoint, "camera relay", token, max_age: 3600) do
        {:ok, _user_id} -> true
        {:error, _} -> false
      end

    {:ok,
     socket
     |> assign(:page_title, "Phone Camera")
     |> assign(:token, token)
     |> assign(:valid, valid)}
  end
end
