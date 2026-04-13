defmodule TabletopWeb.GameLive.PreJoin do
  use TabletopWeb, :live_view

  alias Tabletop.Games
  alias Tabletop.Games.Game

  on_mount {TabletopWeb.UserAuth, :require_authenticated}

  @reservation_timeout_ms 120_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} current_scope={@current_scope}>
      <div
        id="pre-join"
        phx-hook=".PreJoinCamera"
        data-game-id={@game.id}
        data-user-token={@user_token}
        data-camera-relay-token={@camera_relay_token}
        class="flex flex-col h-full"
      >
        <%!-- Top bar --%>
        <div class="flex items-center gap-3 px-3 py-2 bg-base-200 border-b border-base-300">
          <video id="pre-join-video" autoplay muted playsinline class="hidden"></video>

          <div class="flex-1 text-center">
            <span class="font-semibold">{@game.title}</span>
            <span class="text-sm opacity-75 ml-2">{Game.format_name(@game)}</span>
            <span :if={@mode == :joiner} class="text-sm opacity-75 ml-2">
              vs {@game.user.name}
            </span>
          </div>

          <div id="pre-join-status" phx-update="ignore" class="badge badge-sm badge-outline">
            Initializing...
          </div>
        </div>

        <%!-- Main area --%>
        <div class="flex flex-1 min-h-0">
          <%!-- Central area — camera preview --%>
          <div class="flex-1 relative bg-base-300">
            <canvas id="pre-join-canvas" class="w-full h-full"></canvas>

            <%!-- No camera overlay --%>
            <div
              id="pre-join-no-camera"
              class="absolute inset-0 flex items-center justify-center bg-base-300 hidden"
            >
              <div class="text-center">
                <.icon name="hero-video-camera-slash" class="size-16 mx-auto mb-3 opacity-50" />
                <p class="text-lg opacity-75">Camera not available</p>
                <p class="text-sm opacity-50 mt-1">Check your browser permissions</p>
              </div>
            </div>

            <%!-- Bottom bar: source toggle + actions --%>
            <div class="absolute bottom-4 left-1/2 -translate-x-1/2 flex items-center gap-4 bg-base-200/90 rounded-lg px-4 py-3 backdrop-blur-sm">
              <%!-- Camera source toggle --%>
              <div class="flex items-center gap-2">
                <span class="text-xs font-semibold">Source:</span>
                <button
                  id="pre-join-webcam-btn"
                  type="button"
                  class="btn btn-xs btn-active"
                >
                  <.icon name="hero-video-camera" class="size-4" /> Webcam
                </button>
                <button
                  id="pre-join-phone-btn"
                  type="button"
                  class="btn btn-xs btn-outline"
                  disabled
                >
                  <.icon name="hero-device-phone-mobile" class="size-4" /> Phone
                </button>
              </div>

              <div class="divider divider-horizontal mx-0"></div>

              <%!-- Phone connection --%>
              <div class="flex items-center gap-2">
                <div id="pre-join-phone-status" phx-update="ignore">
                  <span class="badge badge-sm badge-outline">Phone not connected</span>
                </div>
                <button
                  id="pre-join-connect-phone-btn"
                  type="button"
                  class="btn btn-xs btn-outline"
                >
                  <.icon name="hero-qr-code" class="size-4" /> Connect Phone
                </button>
              </div>

              <div class="divider divider-horizontal mx-0"></div>

              <%!-- Actions --%>
              <.link navigate={~p"/"} class="btn btn-sm btn-outline">
                Cancel
              </.link>
              <button
                id="pre-join-continue-btn"
                type="button"
                phx-click="continue"
                class="btn btn-sm btn-primary"
              >
                Continue
              </button>
            </div>

            <%!-- QR code panel --%>
            <div
              id="pre-join-qr-panel"
              class="absolute top-4 right-4 bg-base-200/90 rounded-lg p-4 backdrop-blur-sm hidden"
            >
              <div class="flex items-center justify-between mb-2">
                <p class="text-sm font-semibold">Scan with your phone</p>
                <button id="pre-join-qr-close" type="button" class="btn btn-xs btn-ghost btn-circle">
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
              <div class="bg-white p-2 rounded">{raw(@qr_svg)}</div>
              <p class="text-xs opacity-60 mt-2 text-center">
                Open the link on your phone to connect its camera
              </p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.game>

    <script :type={ColocatedHook} name=".PreJoinCamera">
      import CameraRelayReceiver from "@/js/camera_relay_receiver.js"

      export default {
        mounted() {
          const el = this.el
          const gameId = el.dataset.gameId

          console.log("[PreJoin] mounted, gameId:", gameId)

          // Require camera setup before pre-join
          if (localStorage.getItem("tabletop:camera-setup-done") !== "true") {
            console.log("[PreJoin] camera setup not done, redirecting")
            window.location.href = `/camera-setup?redirect=/games/${gameId}/pre-join&game_id=${gameId}`
            return
          }

          // Skip pre-join if camera already confirmed for this game
          if (localStorage.getItem(`tabletop:camera-confirmed:${gameId}`) === "true") {
            console.log("[PreJoin] already confirmed, skipping to game")
            window.location.href = `/games/${gameId}`
            return
          }

          console.log("[PreJoin] showing camera preview")
          const videoEl = document.getElementById("pre-join-video")
          const canvasEl = document.getElementById("pre-join-canvas")
          const noCameraEl = document.getElementById("pre-join-no-camera")
          const statusEl = document.getElementById("pre-join-status")
          const webcamBtn = document.getElementById("pre-join-webcam-btn")
          const phoneBtn = document.getElementById("pre-join-phone-btn")
          const phoneStatusEl = document.getElementById("pre-join-phone-status")
          const connectPhoneBtn = document.getElementById("pre-join-connect-phone-btn")
          const qrPanel = document.getElementById("pre-join-qr-panel")
          const qrCloseBtn = document.getElementById("pre-join-qr-close")

          let stream = null
          let phoneStream = null
          let animFrameId = null
          let usingPhone = false

          // Read stored camera settings (read-only, no sliders)
          const zoom = parseFloat(localStorage.getItem("tabletop:camera-zoom") || "1")
          const rotation = parseFloat(localStorage.getItem("tabletop:camera-rotation") || "0") * Math.PI / 180

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

                // Source crop for zoom (center crop)
                const sw = vw / zoom
                const sh = vh / zoom
                const sx = (vw - sw) / 2
                const sy = (vh - sh) / 2

                // Base cover scale (no rotation)
                const baseScale = Math.max(cw / sw, ch / sh)
                let dw = sw * baseScale
                let dh = sh * baseScale

                // Rotation bounding box compensation
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

          const updateSourceButtons = () => {
            if (usingPhone) {
              phoneBtn.classList.add("btn-active")
              phoneBtn.classList.remove("btn-outline")
              webcamBtn.classList.remove("btn-active")
              webcamBtn.classList.add("btn-outline")
            } else {
              webcamBtn.classList.add("btn-active")
              webcamBtn.classList.remove("btn-outline")
              phoneBtn.classList.remove("btn-active")
              phoneBtn.classList.add("btn-outline")
            }
            phoneBtn.disabled = !phoneStream

            // Hide connect button once phone is connected
            if (phoneStream) {
              connectPhoneBtn.classList.add("hidden")
            } else {
              connectPhoneBtn.classList.remove("hidden")
            }
          }

          // Start webcam
          const start = async () => {
            console.log("[PreJoin] start() called, requesting getUserMedia")
            try {
              stream = await navigator.mediaDevices.getUserMedia({
                video: { width: { ideal: 1920 }, height: { ideal: 1080 } },
                audio: true,
              })
              console.log("[PreJoin] getUserMedia succeeded, stream:", stream.id)
              videoEl.srcObject = stream
              await videoEl.play().catch(() => {})
              console.log("[PreJoin] video readyState:", videoEl.readyState)
              noCameraEl.classList.add("hidden")
              statusEl.textContent = "Camera active"
              statusEl.className = "badge badge-sm badge-success"
              console.log("[PreJoin] canvas size:", canvasEl.clientWidth, "x", canvasEl.clientHeight)
              startCanvasRender()
            } catch (err) {
              console.error("[PreJoin] Failed to get user media:", err)
              noCameraEl.classList.remove("hidden")
              statusEl.textContent = "No camera"
              statusEl.className = "badge badge-sm badge-warning"
            }
          }

          // Start webcam first
          console.log("[PreJoin] calling start()")
          start()

          // Phone camera relay
          const token = el.dataset.userToken
          const relayToken = el.dataset.cameraRelayToken

          this.cameraRelay = new CameraRelayReceiver({
            token,
            relayToken,
            onStream: (remoteStream) => {
              phoneStream = remoteStream
              phoneStatusEl.innerHTML = '<span class="badge badge-sm badge-success">Phone connected</span>'
              phoneBtn.disabled = false
              updateSourceButtons()
            },
            onDisconnect: () => {
              phoneStream = null
              phoneStatusEl.innerHTML = '<span class="badge badge-sm badge-outline">Phone not connected</span>'
              if (usingPhone) {
                videoEl.srcObject = stream
                usingPhone = false
              }
              updateSourceButtons()
            },
          })
          this.cameraRelay.start()

          // Connect Phone button — toggles QR panel
          connectPhoneBtn.addEventListener("click", () => {
            qrPanel.classList.toggle("hidden")
          })

          // Close QR panel
          qrCloseBtn.addEventListener("click", () => {
            qrPanel.classList.add("hidden")
          })

          // Source toggle buttons
          phoneBtn.addEventListener("click", () => {
            if (phoneStream && !usingPhone) {
              videoEl.srcObject = phoneStream
              videoEl.play().catch(() => {})
              usingPhone = true
              updateSourceButtons()
              qrPanel.classList.add("hidden")
            }
          })

          webcamBtn.addEventListener("click", () => {
            if (usingPhone) {
              videoEl.srcObject = stream
              videoEl.play().catch(() => {})
              usingPhone = false
              updateSourceButtons()
            }
          })

          // Store camera settings on continue so the game show page
          // knows the user confirmed their camera and which source to use
          const continueBtn = document.getElementById("pre-join-continue-btn")
          continueBtn.addEventListener("click", () => {
            localStorage.setItem(`tabletop:camera-confirmed:${gameId}`, "true")
            localStorage.setItem("tabletop:camera-source", usingPhone ? "phone" : "webcam")
          })

          this.cleanup = () => {
            if (animFrameId) cancelAnimationFrame(animFrameId)
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
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    game = Games.get_game!(scope, id)

    # If the user already belongs to the game (creator or already-joined opponent),
    # treat as :creator mode (no reservation needed, just camera confirm).
    # Only use :joiner mode for users who haven't joined yet.
    mode =
      if Games.user_part_of_game?(scope, game) do
        :creator
      else
        :joiner
      end

    socket = mount_pre_join(socket, game, mode, scope)
    {:ok, socket}
  end

  defp mount_pre_join(socket, game, :creator, scope) do
    if connected?(socket) do
      Games.subscribe_games(scope)
    end

    user_token = Phoenix.Token.sign(socket, "user socket", scope.user.id)
    camera_relay_token = Phoenix.Token.sign(socket, "camera relay", scope.user.id)
    qr_url = "#{TabletopWeb.Endpoint.url()}/phone-camera/#{camera_relay_token}"
    qr_svg = qr_url |> EQRCode.encode() |> EQRCode.svg(width: 200)

    socket
    |> assign(:page_title, "Pre-Join: #{game.title}")
    |> assign(:game, game)
    |> assign(:mode, :creator)
    |> assign(:user_token, user_token)
    |> assign(:camera_relay_token, camera_relay_token)
    |> assign(:qr_svg, qr_svg)
  end

  defp mount_pre_join(socket, game, :joiner, scope) do
    if connected?(socket) do
      Games.subscribe_games(scope)
    end

    case Games.reserve_join(scope, game) do
      {:ok, game} ->
        if connected?(socket) do
          Process.send_after(self(), :reservation_expired, @reservation_timeout_ms)
        end

        user_token = Phoenix.Token.sign(socket, "user socket", scope.user.id)
        camera_relay_token = Phoenix.Token.sign(socket, "camera relay", scope.user.id)
        qr_url = "#{TabletopWeb.Endpoint.url()}/phone-camera/#{camera_relay_token}"
        qr_svg = qr_url |> EQRCode.encode() |> EQRCode.svg(width: 200)

        socket
        |> assign(:page_title, "Pre-Join: #{game.title}")
        |> assign(:game, game)
        |> assign(:mode, :joiner)
        |> assign(:user_token, user_token)
        |> assign(:camera_relay_token, camera_relay_token)
        |> assign(:qr_svg, qr_svg)

      {:error, :unavailable} ->
        socket
        |> put_flash(:error, "Game is no longer available")
        |> push_navigate(to: ~p"/")
        |> assign(:game, game)
        |> assign(:mode, :joiner)
        |> assign(:user_token, "")
        |> assign(:camera_relay_token, "")
        |> assign(:qr_svg, "")
    end
  end

  @impl true
  def handle_event("continue", _params, socket) do
    case socket.assigns.mode do
      :creator ->
        {:noreply, push_navigate(socket, to: ~p"/games/#{socket.assigns.game}")}

      :joiner ->
        case Games.join_game(socket.assigns.current_scope, socket.assigns.game) do
          {:ok, game} ->
            {:noreply,
             socket
             |> put_flash(:info, "Joined game successfully")
             |> push_navigate(to: ~p"/games/#{game}")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Unable to join game. It may no longer be available.")
             |> push_navigate(to: ~p"/")}
        end
    end
  end

  @impl true
  def handle_info(:reservation_expired, socket) do
    if socket.assigns.mode == :joiner do
      {:noreply,
       socket
       |> put_flash(:error, "Join reservation expired. Please try again.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:deleted, %Game{id: id}}, %{assigns: %{game: %{id: id}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "The game was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({_type, %Game{}}, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:mode] == :joiner and socket.assigns[:current_scope] do
      Games.release_reservation(socket.assigns.current_scope, socket.assigns.game.id)
    end

    :ok
  end
end
