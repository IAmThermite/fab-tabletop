defmodule TabletopWeb.CameraSetupLive do
  use TabletopWeb, :live_view
  use TabletopWeb.CardLookup

  alias Tabletop.Fab.GameState
  alias Tabletop.Games

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} current_scope={@current_scope}>
      <div
        id="camera-setup"
        phx-hook=".CameraSetup"
        data-redirect={@redirect_to}
        data-game-id={@game_id}
        data-user-token={@user_token}
        data-camera-relay-token={@camera_relay_token}
        data-relay-user-id={@relay_user_id}
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

          <button
            id="settings-btn"
            type="button"
            class="btn btn-circle btn-sm"
            title="Settings"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" />
          </button>

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
            create_token_open={@create_token_open}
            create_proxy_token_open={@create_proxy_token_open}
          />

          <%!-- Central area — camera preview canvas --%>
          <div
            id="game-area"
            class="flex-1 relative bg-blue-100 flex items-center justify-center overflow-hidden"
            style="container-type: size;"
          >
            <div class="aspect-video" style="width: min(100cqw, 100cqh * 16 / 9);">
              <canvas id="test-canvas" class="w-full h-full block"></canvas>
            </div>

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

            <%!-- Zoom/rotation controls. Wrapped in phx-update="ignore" so a
                 LiveView re-render (e.g. when a card popout opens) doesn't
                 reset the slider values back to the template defaults. --%>
            <div
              id="camera-adjust-controls"
              phx-update="ignore"
              class="absolute bottom-4 left-1/2 -translate-x-1/2 flex items-center gap-4 bg-base-200/90 rounded-lg px-4 py-2 backdrop-blur-sm"
            >
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

            <.game_tiles game_state={@game_state} context={:setup} />

            <.proxy_tokens_panel game_state={@game_state} expanded={@proxy_tokens_expanded} />

            <.card_popouts open_cards={@open_cards} />
          </div>
        </div>

        <.settings_dialog qr_svg={@qr_svg} show_reconfigure_link={false} />
      </div>
    </Layouts.game>

    <script :type={ColocatedHook} name=".CameraSetup">
      import { setupCardLookup, preloadScanner } from "@/js/card_scanner/liveview_hook.js"
      import { isDebugEnabled, setDebugEnabled } from "@/js/card_scanner/debug.js"
      import CameraRelayReceiver from "@/js/camera_relay_receiver.js"

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
          const settingsBtn = document.getElementById("settings-btn")
          const settingsDialog = document.getElementById("settings-dialog")
          const flipToggle = document.getElementById("flip-opponent-toggle")

          let stream = null
          let animFrameId = null
          let audioContext = null
          let analyser = null
          let cameraEnabled = true
          let micEnabled = true

          // Settings dialog
          settingsBtn.addEventListener("click", () => settingsDialog.showModal())

          // Load saved settings from localStorage
          debugToggle.checked = isDebugEnabled()
          debugToggle.addEventListener("change", () => setDebugEnabled(debugToggle.checked))

          // Flip toggle (load preference but no canvas to flip on setup page)
          const FLIP_KEY = "tabletop:flip-opponent"
          flipToggle.checked = localStorage.getItem(FLIP_KEY) === "true"
          flipToggle.addEventListener("change", () => {
            localStorage.setItem(FLIP_KEY, flipToggle.checked)
          })

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
            const videoBase = { width: { ideal: 1920 }, height: { ideal: 1080 } }
            try {
              try {
                stream = await navigator.mediaDevices.getUserMedia({
                  video: { ...videoBase, aspectRatio: { exact: 16 / 9 } },
                  audio: true,
                })
              } catch (err) {
                if (err && err.name === "OverconstrainedError") {
                  console.warn("[CameraSetup] Camera rejected 16:9 constraint, falling back")
                  stream = await navigator.mediaDevices.getUserMedia({
                    video: videoBase,
                    audio: true,
                  })
                } else {
                  throw err
                }
              }
              videoEl.srcObject = stream
              await videoEl.play().catch(() => {})
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

            const gameId = el.dataset.gameId
            if (gameId) {
              // When invoked from a game's pre-join flow, jump straight into
              // the game (joining if needed) instead of bouncing back through
              // pre-join.
              localStorage.setItem(`tabletop:camera-confirmed:${gameId}`, "true")
              localStorage.setItem("tabletop:camera-source", this._usingPhone ? "phone" : "webcam")
              this.pushEvent("save_and_join", {})
            } else {
              const redirect = el.dataset.redirect
              window.location.href = redirect || "/"
            }
          })

          start()

          // Card lookup — click on canvas to identify the card via pHash
          const gameArea = document.getElementById("game-area")
          preloadScanner()
          setupCardLookup(this, canvasEl, gameArea)

          // --- Phone Camera Relay ---
          const token = el.dataset.userToken
          const relayUserId = el.dataset.relayUserId
          const phoneStatusEl = document.getElementById("phone-camera-status")
          const usePhoneBtn = document.getElementById("use-phone-camera-btn")
          const useWebcamBtn = document.getElementById("use-webcam-btn")

          let phoneStream = null
          this._usingPhone = false

          const updateSourceButtons = () => {
            if (this._usingPhone) {
              usePhoneBtn.classList.add("btn-active")
              usePhoneBtn.classList.remove("btn-outline")
              useWebcamBtn.classList.remove("btn-active")
              useWebcamBtn.classList.add("btn-outline")
            } else {
              useWebcamBtn.classList.add("btn-active")
              useWebcamBtn.classList.remove("btn-outline")
              usePhoneBtn.classList.remove("btn-active")
              usePhoneBtn.classList.add("btn-outline")
            }
            usePhoneBtn.disabled = !phoneStream
          }

          this.cameraRelay = new CameraRelayReceiver({
            token,
            relayUserId,
            onStream: (remoteStream) => {
              phoneStream = remoteStream
              phoneStatusEl.innerHTML = '<span class="badge badge-sm badge-success">Phone connected</span>'
              usePhoneBtn.disabled = false
              updateSourceButtons()
            },
            onDisconnect: () => {
              phoneStream = null
              phoneStatusEl.innerHTML = '<span class="badge badge-sm badge-outline">Phone not connected</span>'
              if (this._usingPhone) {
                // Switch back to webcam
                videoEl.srcObject = stream
                this._usingPhone = false
              }
              updateSourceButtons()
            },
          })
          this.cameraRelay.start()

          usePhoneBtn.addEventListener("click", () => {
            if (phoneStream && !this._usingPhone) {
              videoEl.srcObject = phoneStream
              videoEl.play().catch(() => {})
              this._usingPhone = true
              updateSourceButtons()
            }
          })

          useWebcamBtn.addEventListener("click", () => {
            if (this._usingPhone) {
              videoEl.srcObject = stream
              videoEl.play().catch(() => {})
              this._usingPhone = false
              updateSourceButtons()
            }
          })

          this.cleanup = () => {
            if (animFrameId) cancelAnimationFrame(animFrameId)
            if (audioContext) audioContext.close()
            if (stream) stream.getTracks().forEach(t => t.stop())
            if (this.cameraRelay) this.cameraRelay.disconnect()
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
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    user_id =
      if scope && scope.user,
        do: scope.user.id,
        else: "anon:#{Base.encode64(:crypto.strong_rand_bytes(16))}"

    user_token = Phoenix.Token.sign(socket, "user socket", user_id)
    camera_relay_token = Phoenix.Token.sign(socket, "camera relay", user_id)
    qr_url = "#{TabletopWeb.Endpoint.url()}/phone-camera/#{camera_relay_token}"
    qr_svg = qr_url |> EQRCode.encode() |> EQRCode.svg(width: 200)

    {:ok,
     socket
     |> assign(:page_title, "Camera Setup")
     |> assign(:redirect_to, params["redirect"])
     |> assign(:game_id, params["game_id"])
     |> assign(:user_token, user_token)
     |> assign(:camera_relay_token, camera_relay_token)
     |> assign(:relay_user_id, user_id)
     |> assign(:qr_svg, qr_svg)
     |> assign(:game_state, new_preview_state())
     |> assign(:abilities_open, false)
     |> assign(:on_hits_open, false)
     |> assign(:create_token_open, false)
     |> assign(:create_proxy_token_open, false)
     |> assign(:proxy_tokens_expanded, false)
     |> assign(:open_cards, [])}
  end

  @impl true
  def handle_event("save_and_join", _params, socket) do
    scope = socket.assigns.current_scope
    game_id = socket.assigns.game_id

    with %{user: %{id: _}} <- scope,
         {:ok, game} <- fetch_game_for_setup(scope, game_id) do
      if Games.user_part_of_game?(scope, game) do
        {:noreply, push_navigate(socket, to: ~p"/games/#{game}")}
      else
        case Games.join_game(scope, game) do
          {:ok, game} ->
            {:noreply,
             socket
             |> put_flash(:info, "Joined game successfully")
             |> push_navigate(to: ~p"/games/#{game}")}

          {:error, :already_in_game} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "You're already in a game. Finish or leave it before joining another."
             )
             |> push_navigate(to: ~p"/")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Unable to join game. It may no longer be available.")
             |> push_navigate(to: ~p"/")}
        end
      end
    else
      _ -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  def handle_event("toggle_damage", %{"type" => type}, socket) do
    apply_action(socket, GameState.toggle_damage(my(socket), validate_damage_type(type)))
  end

  def handle_event("change_damage", %{"type" => type, "delta" => delta}, socket) do
    apply_action(
      socket,
      GameState.change_damage(my(socket), validate_damage_type(type), String.to_integer(delta))
    )
  end

  def handle_event("toggle_goagain", _params, socket) do
    apply_action(socket, GameState.toggle_goagain(my(socket)))
  end

  def handle_event("toggle_effect", %{"type" => type, "category" => category}, socket) do
    apply_action(socket, GameState.toggle_effect(my(socket), category, type))
  end

  def handle_event(
        "change_effect_count",
        %{"type" => type, "category" => category, "delta" => delta},
        socket
      ) do
    apply_action(
      socket,
      GameState.change_effect_count(my(socket), category, type, String.to_integer(delta))
    )
  end

  def handle_event("change_life", %{"delta" => delta}, socket) do
    apply_action(socket, GameState.change_life(my(socket), String.to_integer(delta)))
  end

  def handle_event("reset_chain", _params, socket) do
    apply_action(socket, GameState.reset_chain(my(socket)))
  end

  def handle_event(
        "move_tile",
        %{"tile_id" => tile_id, "x" => x, "y" => y, "owner" => _owner},
        socket
      ) do
    apply_action(socket, GameState.move_tile(my(socket), tile_id, to_float(x), to_float(y)))
  end

  def handle_event("toggle_dropdown", %{"name" => "abilities"}, socket) do
    {:noreply, assign(socket, :abilities_open, !socket.assigns.abilities_open)}
  end

  def handle_event("toggle_dropdown", %{"name" => "on_hits"}, socket) do
    new_open = !socket.assigns.on_hits_open

    socket =
      socket
      |> assign(:on_hits_open, new_open)
      |> assign(:create_token_open, new_open && socket.assigns.create_token_open)

    {:noreply, socket}
  end

  def handle_event("toggle_dropdown", %{"name" => "create_token"}, socket) do
    {:noreply, assign(socket, :create_token_open, !socket.assigns.create_token_open)}
  end

  def handle_event("toggle_dropdown", %{"name" => "create_proxy_token"}, socket) do
    {:noreply, assign(socket, :create_proxy_token_open, !socket.assigns.create_proxy_token_open)}
  end

  def handle_event("toggle_dropdown", %{"name" => "proxy_tokens_panel"}, socket) do
    {:noreply, assign(socket, :proxy_tokens_expanded, !socket.assigns.proxy_tokens_expanded)}
  end

  def handle_event("add_proxy_token", %{"type" => name}, socket) do
    apply_action(socket, GameState.add_proxy_token(my(socket), name))
  end

  def handle_event("remove_proxy_token", %{"type" => name}, socket) do
    apply_action(socket, GameState.remove_proxy_token(my(socket), name))
  end

  defp my(socket), do: socket.assigns.game_state.my

  defp fetch_game_for_setup(_scope, nil), do: {:error, :not_found}
  defp fetch_game_for_setup(scope, id), do: Games.get_game(scope, id)

  defp apply_action(socket, {:ok, new_player, _broadcast_msg}) do
    {:noreply, assign(socket, :game_state, %{socket.assigns.game_state | my: new_player})}
  end

  defp apply_action(socket, {:error, _reason}) do
    {:noreply, socket}
  end

  defp new_preview_state do
    %{my: GameState.default_player(), opponent: GameState.default_player()}
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
