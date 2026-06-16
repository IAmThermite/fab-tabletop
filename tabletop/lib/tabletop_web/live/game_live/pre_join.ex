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
        data-skip-allowed={to_string(@mode == :creator)}
        class="flex flex-col h-full"
      >
        <%!-- Share-code prompt (one-time, after creating a private game) --%>
        <div
          :if={@share_code_prompt}
          class="px-3 py-2 bg-success/10 border-b border-success/30 flex items-center gap-3"
        >
          <.icon name="hero-check-circle" class="size-5 text-success shrink-0" />
          <div class="flex-1 min-w-0">
            <p class="font-semibold text-sm">Private game created</p>
            <p class="text-xs opacity-75 truncate">
              Send this code to your opponent:
              <span class="font-mono ml-1 select-all">{@share_code_prompt}</span>
            </p>
          </div>
          <.share_code_button
            id="pre-join-prompt-share-btn"
            code={@share_code_prompt}
            label="Share code"
          />
          <button
            type="button"
            phx-click="dismiss_share_prompt"
            class="btn btn-xs btn-ghost btn-circle"
            aria-label="Dismiss"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

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

        <%!-- Waiting-for-opponent banner (creator only, no active joiner) --%>
        <div
          :if={@mode == :creator and @game.status == :waiting and not joiner_reserved?(@game)}
          class="px-3 py-2 bg-primary/10 border-b border-primary/30 flex items-center gap-3"
        >
          <div class="flex-1 min-w-0">
            <p class="font-semibold text-sm">Waiting for opponent</p>
            <p class="text-xs opacity-75 truncate">
              Share this code so they can join:
              <span class="font-mono ml-1 select-all">{@game.id}</span>
            </p>
          </div>
          <.share_code_button id="pre-join-banner-share-btn" code={@game.id} label="Share code" />
        </div>

        <%!-- Main area --%>
        <div class="flex flex-1 min-h-0">
          <%!-- Central area — camera preview --%>
          <div
            class="flex-1 relative bg-base-300 flex items-center justify-center overflow-hidden"
            style="container-type: size;"
          >
            <div class="aspect-video" style="width: min(100cqw, 100cqh * 16 / 9);">
              <canvas id="pre-join-canvas" class="w-full h-full block"></canvas>
            </div>

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

              <%!-- Share (creator only) --%>
              <%= if @mode == :creator do %>
                <.share_code_button
                  id="pre-join-bottom-share-btn"
                  code={@game.id}
                  label="Share"
                  class="btn btn-xs btn-outline"
                />
                <div class="divider divider-horizontal mx-0"></div>
              <% end %>

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

          // Mark this game's camera confirmed only once the server confirms the
          // user is a participant (creator, or a successful join) — never
          // optimistically on click — so a failed join can't set the flag and
          // make this screen skip itself (and the join) on the next visit.
          this.handleEvent("camera_confirmed", ({ game_id }) => {
            localStorage.setItem(`tabletop:camera-confirmed:${game_id}`, "true")
          })

          // Require camera setup before pre-join
          if (localStorage.getItem("tabletop:camera-setup-done") !== "true") {
            console.log("[PreJoin] camera setup not done, redirecting")
            window.location.href = `/camera-setup?redirect=/games/${gameId}/pre-join&game_id=${gameId}`
            return
          }

          // Skip pre-join only for a user already in the game who has confirmed
          // their camera for it. Never skip for a not-yet-joined user: skipping
          // bypasses the join (which happens on "Continue") and would dead-end
          // them on the game page as a non-participant. `skipAllowed` is driven
          // by the server (true only when the user is already a participant), so
          // a stale `camera-confirmed` flag can't strand them.
          const skipAllowed = el.dataset.skipAllowed === "true"
          if (skipAllowed && localStorage.getItem(`tabletop:camera-confirmed:${gameId}`) === "true") {
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
            const videoBase = { width: { ideal: 1920 }, height: { ideal: 1080 } }
            try {
              try {
                stream = await navigator.mediaDevices.getUserMedia({
                  video: { ...videoBase, aspectRatio: { exact: 16 / 9 } },
                  audio: true,
                })
              } catch (err) {
                if (err && err.name === "OverconstrainedError") {
                  console.warn("[PreJoin] Camera rejected 16:9 constraint, falling back")
                  stream = await navigator.mediaDevices.getUserMedia({
                    video: videoBase,
                    audio: true,
                  })
                } else {
                  throw err
                }
              }
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

          // Store the chosen camera source on continue. The `camera-confirmed`
          // flag is set by the server's "camera_confirmed" event only once it
          // confirms participation, not here, so a failed join never marks the
          // game confirmed.
          const continueBtn = document.getElementById("pre-join-continue-btn")
          continueBtn.addEventListener("click", () => {
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

    if is_nil(scope.user.confirmed_at) do
      {:ok,
       socket
       |> put_flash(:error, "Please confirm your email address before joining a game.")
       |> redirect(to: ~p"/")}
    else
      # Unscoped lookup: the user reaching pre-join may not yet be a participant
      # (they're considering joining); possession of the UUID is the invitation.
      case Games.fetch_game(id) do
        {:ok, game} ->
          mode = if Games.user_part_of_game?(scope, game), do: :creator, else: :joiner

          socket =
            socket
            |> mount_pre_join(game, mode, scope)
            |> assign_share_code_prompt()

          {:ok, socket}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Game not found.")
           |> redirect(to: ~p"/")}
      end
    end
  end

  defp assign_share_code_prompt(socket) do
    case Phoenix.Flash.get(socket.assigns.flash, :share_code) do
      nil ->
        assign(socket, :share_code_prompt, nil)

      code ->
        socket
        |> clear_flash(:share_code)
        |> assign(:share_code_prompt, code)
    end
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

      {:error, reason} ->
        message =
          case reason do
            :already_in_game ->
              "You're already in a game. Finish or leave it before joining another."

            _ ->
              "Game is no longer available"
          end

        socket
        |> put_flash(:error, message)
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
        game = socket.assigns.game

        {:noreply,
         socket
         |> push_event("camera_confirmed", %{game_id: game.id})
         |> push_navigate(to: ~p"/games/#{game}")}

      :joiner ->
        case Games.join_game(socket.assigns.current_scope, socket.assigns.game) do
          {:ok, game} ->
            {:noreply,
             socket
             |> put_flash(:info, "Joined game successfully")
             |> push_event("camera_confirmed", %{game_id: game.id})
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
  end

  def handle_event("dismiss_share_prompt", _params, socket) do
    {:noreply, assign(socket, :share_code_prompt, nil)}
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

  def handle_info({:updated, %Game{id: id} = game}, %{assigns: %{game: %Game{id: id}}} = socket) do
    {:noreply, assign(socket, :game, game)}
  end

  def handle_info({_type, %Game{}}, socket) do
    {:noreply, socket}
  end

  defp joiner_reserved?(%Game{joining_user_id: nil}), do: false
  defp joiner_reserved?(%Game{joining_expires_at: nil}), do: false

  defp joiner_reserved?(%Game{joining_expires_at: expires}),
    do: DateTime.compare(expires, DateTime.utc_now()) == :gt

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:mode] == :joiner and socket.assigns[:current_scope] do
      Games.release_reservation(socket.assigns.current_scope, socket.assigns.game.id)
    end

    :ok
  end
end
