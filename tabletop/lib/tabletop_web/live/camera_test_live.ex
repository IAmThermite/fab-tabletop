defmodule TabletopWeb.CameraTestLive do
  use TabletopWeb, :live_view

  alias Tabletop.Fab.GameState

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} current_scope={@current_scope}>
      <div id="camera-test" phx-hook=".CameraTest" class="flex flex-col h-full">
        <%!-- Top bar --%>
        <div class="flex items-center gap-3 px-3 py-2 bg-base-200 border-b border-base-300">
          <video
            id="test-local-video"
            autoplay
            muted
            playsinline
            class="w-24 h-18 rounded object-cover bg-black"
          >
          </video>

          <button
            id="test-toggle-camera"
            type="button"
            class="btn btn-circle btn-sm"
            title="Toggle camera"
          >
            <span class="icon-on"><.icon name="hero-video-camera" class="size-5" /></span>
            <span class="icon-off hidden">
              <.icon name="hero-video-camera-slash" class="size-5" />
            </span>
          </button>

          <button
            id="test-toggle-mic"
            type="button"
            class="btn btn-circle btn-sm"
            title="Toggle microphone"
          >
            <span class="icon-on"><.icon name="hero-microphone" class="size-5" /></span>
            <span class="icon-off hidden">
              <.icon name="hero-microphone" class="size-5 opacity-50" />
            </span>
          </button>

          <div class="flex-1 text-center font-semibold truncate">
            Camera Test
          </div>

          <div id="test-audio-level" phx-update="ignore" class="flex items-center gap-2">
            <span class="text-xs opacity-75">Mic:</span>
            <div class="w-20 h-2 bg-base-300 rounded-full overflow-hidden">
              <div
                id="test-audio-bar"
                class="h-full bg-success transition-all duration-100"
                style="width: 0%"
              >
              </div>
            </div>
          </div>

          <div id="test-status" phx-update="ignore" class="badge badge-sm badge-outline">
            Initializing...
          </div>

          <.link navigate={~p"/"} class="btn btn-circle btn-sm">
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>

        <%!-- Main area --%>
        <div class="flex flex-1 min-h-0">
          <.game_sidebar game_state={@game_state} />

          <%!-- Central area — opponent view canvas --%>
          <div class="flex-1 relative bg-blue-100">
            <canvas id="test-canvas" class="w-full h-full"></canvas>

            <%!-- No camera overlay --%>
            <div
              id="test-no-camera"
              class="absolute inset-0 flex items-center justify-center bg-base-300 hidden"
            >
              <div class="text-center">
                <.icon name="hero-video-camera-slash" class="size-16 mx-auto mb-3 opacity-50" />
                <p class="text-lg opacity-75">Camera not available</p>
                <p class="text-sm opacity-50 mt-1">Check your browser permissions</p>
              </div>
            </div>

            <.game_overlays game_state={@game_state} />
          </div>
        </div>
      </div>
    </Layouts.game>

    <script :type={ColocatedHook} name=".CameraTest">
      export default {
        mounted() {
          const videoEl = document.getElementById("test-local-video")
          const canvasEl = document.getElementById("test-canvas")
          const noCameraEl = document.getElementById("test-no-camera")
          const statusEl = document.getElementById("test-status")
          const audioBar = document.getElementById("test-audio-bar")
          const toggleCameraBtn = document.getElementById("test-toggle-camera")
          const toggleMicBtn = document.getElementById("test-toggle-mic")

          let stream = null
          let animFrameId = null
          let audioContext = null
          let analyser = null
          let cameraEnabled = true
          let micEnabled = true

          const updateButtonIcons = (btn, enabled) => {
            const on = btn.querySelector(".icon-on")
            const off = btn.querySelector(".icon-off")
            if (on) on.classList.toggle("hidden", !enabled)
            if (off) off.classList.toggle("hidden", enabled)
            btn.classList.toggle("btn-error", !enabled)
          }

          const startCanvasRender = () => {
            if (animFrameId) return
            const ctx = canvasEl.getContext("2d")

            const render = () => {
              if (videoEl.readyState >= videoEl.HAVE_CURRENT_DATA) {
                const cw = canvasEl.clientWidth
                const ch = canvasEl.clientHeight
                canvasEl.width = cw
                canvasEl.height = ch

                const vw = videoEl.videoWidth
                const vh = videoEl.videoHeight
                const scale = Math.min(cw / vw, ch / vh)
                const dw = vw * scale
                const dh = vh * scale
                const dx = (cw - dw) / 2
                const dy = (ch - dh) / 2

                ctx.clearRect(0, 0, cw, ch)
                ctx.drawImage(videoEl, dx, dy, dw, dh)
              }
              animFrameId = requestAnimationFrame(render)
            }
            animFrameId = requestAnimationFrame(render)
          }

          const startAudioMeter = (mediaStream) => {
            try {
              audioContext = new AudioContext()
              analyser = audioContext.createAnalyser()
              analyser.fftSize = 256
              const source = audioContext.createMediaStreamSource(mediaStream)
              source.connect(analyser)

              const dataArray = new Uint8Array(analyser.frequencyBinCount)
              const updateMeter = () => {
                if (!analyser) return
                analyser.getByteFrequencyData(dataArray)
                const avg = dataArray.reduce((a, b) => a + b, 0) / dataArray.length
                const pct = Math.min(100, Math.round((avg / 128) * 100))
                audioBar.style.width = `${pct}%`
                requestAnimationFrame(updateMeter)
              }
              updateMeter()
            } catch (e) {
              // Web Audio API not available
            }
          }

          const start = async () => {
            try {
              stream = await navigator.mediaDevices.getUserMedia({
                video: { width: { ideal: 1920 }, height: { ideal: 1080 } },
                audio: true,
              })
              videoEl.srcObject = stream
              noCameraEl.classList.add("hidden")
              statusEl.textContent = "Camera active"
              statusEl.className = "badge badge-sm badge-success"
              startCanvasRender()
              startAudioMeter(stream)
            } catch (err) {
              console.error("[CameraTest] Failed to get user media:", err)
              noCameraEl.classList.remove("hidden")
              statusEl.textContent = "No camera"
              statusEl.className = "badge badge-sm badge-warning"
            }
          }

          toggleCameraBtn.addEventListener("click", () => {
            if (!stream) return
            const track = stream.getVideoTracks()[0]
            if (track) {
              cameraEnabled = !cameraEnabled
              track.enabled = cameraEnabled
              updateButtonIcons(toggleCameraBtn, cameraEnabled)
            }
          })

          toggleMicBtn.addEventListener("click", () => {
            if (!stream) return
            const track = stream.getAudioTracks()[0]
            if (track) {
              micEnabled = !micEnabled
              track.enabled = micEnabled
              updateButtonIcons(toggleMicBtn, micEnabled)
            }
          })

          start()

          this.cleanup = () => {
            if (animFrameId) cancelAnimationFrame(animFrameId)
            if (audioContext) audioContext.close()
            if (stream) stream.getTracks().forEach(t => t.stop())
          }
        },

        destroyed() {
          if (this.cleanup) this.cleanup()
        },
      }
    </script>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Camera Test")
     |> assign(:game_state, GameState.new())}
  end

  @impl true
  def handle_event("toggle_damage", %{"type" => type}, socket) do
    apply_action(socket, GameState.toggle_damage(socket.assigns.game_state, validate_damage_type(type)))
  end

  def handle_event("change_damage", %{"type" => type, "delta" => delta}, socket) do
    apply_action(socket, GameState.change_damage(socket.assigns.game_state, validate_damage_type(type), String.to_integer(delta)))
  end

  def handle_event("toggle_goagain", _params, socket) do
    apply_action(socket, GameState.toggle_goagain(socket.assigns.game_state))
  end

  def handle_event("toggle_effect", %{"type" => type}, socket) do
    apply_action(socket, GameState.toggle_effect(socket.assigns.game_state, type))
  end

  def handle_event("change_life", %{"delta" => delta}, socket) do
    apply_action(socket, GameState.change_life(socket.assigns.game_state, String.to_integer(delta)))
  end

  def handle_event("reset_chain", _params, socket) do
    apply_action(socket, GameState.reset_chain(socket.assigns.game_state))
  end

  defp apply_action(socket, {:ok, new_state, _broadcast_msg}) do
    {:noreply, assign(socket, :game_state, new_state)}
  end

  defp apply_action(socket, {:error, _reason}) do
    {:noreply, socket}
  end

  defp validate_damage_type("physical"), do: :physical
  defp validate_damage_type("arcane"), do: :arcane
end
