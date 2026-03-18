defmodule TabletopWeb.CameraSetupLive do
  use TabletopWeb, :live_view
  use TabletopWeb.CardLookup

  alias Tabletop.Fab.GameState

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} current_scope={@current_scope}>
      <div
        id="camera-setup"
        phx-hook=".CameraSetup"
        data-redirect={@redirect_to}
        class="flex flex-col h-full"
      >
        <%!-- Top bar --%>
        <div class="flex items-center gap-3 px-3 py-2 bg-base-200 border-b border-base-300">
          <video
            id="test-local-video"
            autoplay
            muted
            playsinline
            class="hidden"
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
            Camera Setup
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

          <label class="flex items-center gap-2 cursor-pointer text-sm" title="Show OCR debug overlay on card scan">
            <span class="label-text">Debug scan</span>
            <input id="debug-scan-toggle" type="checkbox" class="toggle toggle-sm" />
          </label>

          <button id="setup-done-btn" type="button" class="btn btn-primary btn-sm">
            Save & Continue
          </button>

          <.link navigate={~p"/"} class="btn btn-circle btn-sm">
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>

        <%!-- Main area --%>
        <div class="flex flex-1 min-h-0">
          <.game_sidebar
            game_state={@game_state}
            abilities_open={@abilities_open}
            on_hits_open={@on_hits_open}
          />

          <%!-- Central area — camera preview canvas --%>
          <div id="game-area" class="flex-1 relative bg-blue-100">
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

            <%!-- Zoom/rotation controls --%>
            <div class="absolute bottom-4 left-1/2 -translate-x-1/2 flex items-center gap-4 bg-base-200/90 rounded-lg px-4 py-2 backdrop-blur-sm">
              <div class="flex items-center gap-2">
                <span class="text-xs font-semibold">Rotate</span>
                <input
                  id="rotation-slider"
                  type="range"
                  min="0"
                  max="360"
                  step="1"
                  value="0"
                  class="range range-xs range-secondary w-72"
                />
                <span id="rotation-value" class="text-xs w-8">0&deg;</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-xs font-semibold">Zoom</span>
                <input
                  id="zoom-slider"
                  type="range"
                  min="1"
                  max="3"
                  step="0.1"
                  value="1"
                  class="range range-xs range-primary w-48"
                />
                <span id="zoom-value" class="text-xs w-8">1.0x</span>
              </div>
            </div>

            <.game_tiles game_state={@game_state} context={:remote} />

            <%!-- Card lookup popouts --%>
            <%= for card <- @open_cards do %>
              <div
                id={"card-popout-#{card.id}"}
                phx-hook=".DraggableCardPopout"
                data-x={card.x}
                data-y={card.y}
                class="absolute z-30 w-64 bg-base-100 border border-base-300 rounded-lg shadow-xl overflow-hidden"
                style="left: 0; top: 0;"
              >
                <div class="card-popout-header flex items-center justify-between px-3 py-2 bg-base-200 cursor-grab active:cursor-grabbing touch-none">
                  <span class="font-semibold text-sm truncate flex-1">
                    {card.details.name}
                  </span>
                  <button
                    type="button"
                    phx-click="close_card"
                    phx-value-id={card.id}
                    class="btn btn-circle btn-xs btn-error ml-2"
                    title="Close"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
                <div class="p-3 space-y-2">
                  <img
                    src={card.details.image_url}
                    alt={card.details.name}
                    class="w-full rounded"
                  />
                  <div class="flex justify-between text-xs">
                    <span class="opacity-70">Type:</span>
                    <span class="font-medium">{card.details.type}</span>
                  </div>
                  <div class="flex gap-3 text-xs">
                    <span>Cost: <strong>{card.details.cost}</strong></span>
                    <span>Power: <strong>{card.details.power}</strong></span>
                    <span>Def: <strong>{card.details.defense}</strong></span>
                  </div>
                  <p class="text-xs opacity-85 leading-snug">{card.details.text}</p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.game>

    <script :type={ColocatedHook} name=".CameraSetup">
      import { setupCardLookup, preloadTesseract } from "@/js/card_scanner/liveview_hook.js"
      import { isDebugEnabled, setDebugEnabled } from "@/js/card_scanner/debug.js"

      export default {
        mounted() {
          const el = this.el
          const videoEl = document.getElementById("test-local-video")
          const canvasEl = document.getElementById("test-canvas")
          const noCameraEl = document.getElementById("test-no-camera")
          const statusEl = document.getElementById("test-status")
          const audioBar = document.getElementById("test-audio-bar")
          const toggleCameraBtn = document.getElementById("test-toggle-camera")
          const toggleMicBtn = document.getElementById("test-toggle-mic")
          const zoomSlider = document.getElementById("zoom-slider")
          const zoomValueEl = document.getElementById("zoom-value")
          const rotationSlider = document.getElementById("rotation-slider")
          const rotationValueEl = document.getElementById("rotation-value")
          const doneBtn = document.getElementById("setup-done-btn")
          const debugToggle = document.getElementById("debug-scan-toggle")

          let stream = null
          let animFrameId = null
          let audioContext = null
          let analyser = null
          let cameraEnabled = true
          let micEnabled = true

          // Load saved settings from localStorage
          debugToggle.checked = isDebugEnabled()
          debugToggle.addEventListener("change", () => setDebugEnabled(debugToggle.checked))

          const savedZoom = localStorage.getItem("tabletop:camera-zoom") || "1"
          const savedRotation = localStorage.getItem("tabletop:camera-rotation") || "0"
          zoomSlider.value = savedZoom
          rotationSlider.value = savedRotation
          zoomValueEl.textContent = parseFloat(savedZoom).toFixed(1) + "x"
          rotationValueEl.textContent = savedRotation + "\u00B0"

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
                const zoom = parseFloat(zoomSlider.value)
                const rotation = parseFloat(rotationSlider.value) * Math.PI / 180

                // Source crop for zoom (center crop)
                const sw = vw / zoom
                const sh = vh / zoom
                const sx = (vw - sw) / 2
                const sy = (vh - sh) / 2

                // Base cover scale (no rotation)
                const baseScale = Math.max(cw / sw, ch / sh)
                let dw = sw * baseScale
                let dh = sh * baseScale

                // When rotated, the image must be larger to still cover the canvas.
                // The rotated bounding box of a dw×dh rect needs to cover cw×ch.
                const sinR = Math.abs(Math.sin(rotation))
                const cosR = Math.abs(Math.cos(rotation))
                const rotScale = Math.max(
                  (cw * cosR + ch * sinR) / dw,
                  (cw * sinR + ch * cosR) / dh
                )
                dw *= rotScale
                dh *= rotScale

                const dx = (cw - dw) / 2
                const dy = (ch - dh) / 2

                ctx.clearRect(0, 0, cw, ch)
                ctx.save()
                ctx.translate(cw / 2, ch / 2)
                ctx.rotate(rotation)
                ctx.translate(-cw / 2, -ch / 2)
                ctx.drawImage(videoEl, sx, sy, sw, sh, dx, dy, dw, dh)
                ctx.restore()
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
              console.error("[CameraSetup] Failed to get user media:", err)
              noCameraEl.classList.remove("hidden")
              statusEl.textContent = "No camera"
              statusEl.className = "badge badge-sm badge-warning"
            }
          }

          // Slider listeners — update labels in real-time
          zoomSlider.addEventListener("input", () => {
            zoomValueEl.textContent = parseFloat(zoomSlider.value).toFixed(1) + "x"
          })

          rotationSlider.addEventListener("input", () => {
            rotationValueEl.textContent = rotationSlider.value + "\u00B0"
          })

          // Camera/mic toggles
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

          // Save & Continue
          doneBtn.addEventListener("click", () => {
            localStorage.setItem("tabletop:camera-zoom", zoomSlider.value)
            localStorage.setItem("tabletop:camera-rotation", rotationSlider.value)
            localStorage.setItem("tabletop:camera-setup-done", "true")
            const redirect = el.dataset.redirect
            window.location.href = redirect || "/"
          })

          start()

          // Card lookup — click on canvas to OCR card name
          const gameArea = document.getElementById("game-area")
          preloadTesseract()
          setupCardLookup(this, canvasEl, gameArea)

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

    <script :type={ColocatedHook} name=".DraggableCardPopout">
      export default {
        mounted() {
          const el = this.el
          const header = el.querySelector(".card-popout-header")
          const container = el.parentElement

          const initX = parseFloat(el.dataset.x || "10")
          const initY = parseFloat(el.dataset.y || "10")
          const maxX = container.clientWidth - el.offsetWidth
          const maxY = container.clientHeight - el.offsetHeight
          el.style.left = Math.max(0, Math.min(initX, maxX)) + "px"
          el.style.top = Math.max(0, Math.min(initY, maxY)) + "px"

          let offsetX = 0
          let offsetY = 0

          header.addEventListener("pointerdown", (e) => {
            if (e.target.closest("button")) return
            e.preventDefault()
            header.setPointerCapture(e.pointerId)
            offsetX = e.clientX - el.getBoundingClientRect().left
            offsetY = e.clientY - el.getBoundingClientRect().top
            header.style.cursor = "grabbing"

            container.querySelectorAll("[id^='card-popout-']").forEach((p) => {
              p.style.zIndex = "30"
            })
            el.style.zIndex = "31"
          })

          header.addEventListener("pointermove", (e) => {
            if (!header.hasPointerCapture(e.pointerId)) return
            const rect = container.getBoundingClientRect()
            let newX = e.clientX - rect.left - offsetX
            let newY = e.clientY - rect.top - offsetY
            newX = Math.max(0, Math.min(newX, container.clientWidth - el.offsetWidth))
            newY = Math.max(0, Math.min(newY, container.clientHeight - el.offsetHeight))
            el.style.left = newX + "px"
            el.style.top = newY + "px"
          })

          const onPointerEnd = (e) => {
            if (!header.hasPointerCapture(e.pointerId)) return
            header.releasePointerCapture(e.pointerId)
            header.style.cursor = "grab"
          }

          header.addEventListener("pointerup", onPointerEnd)
          header.addEventListener("pointercancel", onPointerEnd)
        },
      }
    </script>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Camera Setup")
     |> assign(:redirect_to, params["redirect"])
     |> assign(:game_state, GameState.new())
     |> assign(:abilities_open, false)
     |> assign(:on_hits_open, false)
     |> assign(:open_cards, [])}
  end

  @impl true
  def handle_event("toggle_damage", %{"type" => type}, socket) do
    apply_action(
      socket,
      GameState.toggle_damage(socket.assigns.game_state, validate_damage_type(type))
    )
  end

  def handle_event("change_damage", %{"type" => type, "delta" => delta}, socket) do
    apply_action(
      socket,
      GameState.change_damage(
        socket.assigns.game_state,
        validate_damage_type(type),
        String.to_integer(delta)
      )
    )
  end

  def handle_event("toggle_goagain", _params, socket) do
    apply_action(socket, GameState.toggle_goagain(socket.assigns.game_state))
  end

  def handle_event("toggle_effect", %{"type" => type}, socket) do
    apply_action(socket, GameState.toggle_effect(socket.assigns.game_state, type))
  end

  def handle_event("change_life", %{"delta" => delta}, socket) do
    apply_action(
      socket,
      GameState.change_life(socket.assigns.game_state, String.to_integer(delta))
    )
  end

  def handle_event("reset_chain", _params, socket) do
    apply_action(socket, GameState.reset_chain(socket.assigns.game_state))
  end

  def handle_event(
        "move_tile",
        %{"tile_id" => tile_id, "x" => x, "y" => y, "owner" => _owner},
        socket
      ) do
    apply_action(
      socket,
      GameState.move_tile(socket.assigns.game_state, tile_id, to_float(x), to_float(y))
    )
  end

  def handle_event("toggle_dropdown", %{"name" => "abilities"}, socket) do
    {:noreply, assign(socket, :abilities_open, !socket.assigns.abilities_open)}
  end

  def handle_event("toggle_dropdown", %{"name" => "on_hits"}, socket) do
    {:noreply, assign(socket, :on_hits_open, !socket.assigns.on_hits_open)}
  end

  defp apply_action(socket, {:ok, new_state, _broadcast_msg}) do
    {:noreply, assign(socket, :game_state, new_state)}
  end

  defp apply_action(socket, {:error, _reason}) do
    {:noreply, socket}
  end

  defp validate_damage_type("physical"), do: :physical
  defp validate_damage_type("arcane"), do: :arcane

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val * 1.0

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
