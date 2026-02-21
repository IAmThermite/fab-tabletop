defmodule TabletopWeb.GameLive.Show do
  use TabletopWeb, :live_view

  alias Phoenix.LiveView.ColocatedHook
  alias Tabletop.Games

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} current_scope={@current_scope}>
      <div
        id="game-video"
        phx-hook=".GameVideo"
        data-game-id={@game.id}
        data-user-token={@user_token}
        class="flex flex-col h-full"
      >
        <%!-- Top bar --%>
        <div class="flex items-center gap-3 px-3 py-2 bg-base-200 border-b border-base-300">
          <video
            id="local-video"
            autoplay
            muted
            playsinline
            class="w-24 h-18 rounded object-cover bg-black"
          >
          </video>

          <button
            id="toggle-camera"
            type="button"
            class="btn btn-circle btn-sm"
            title="Toggle camera"
          >
            <span class="icon-on"><.icon name="hero-video-camera" class="size-5" /></span>
            <span class="icon-off hidden"><.icon name="hero-video-camera-slash" class="size-5" /></span>
          </button>

          <button
            id="toggle-mic"
            type="button"
            class="btn btn-circle btn-sm"
            title="Toggle microphone"
          >
            <span class="icon-on"><.icon name="hero-microphone" class="size-5" /></span>
            <span class="icon-off hidden"><.icon name="hero-microphone" class="size-5 opacity-50" /></span>
          </button>

          <div class="flex-1 text-center font-semibold truncate">
            {@game.title}
          </div>

          <div id="connection-status" class="badge badge-sm badge-outline">
            Connecting...
          </div>

          <.link navigate={~p"/games"} class="btn btn-circle btn-sm btn-error" title="Leave">
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
          </.link>
        </div>

        <%!-- Main area --%>
        <div class="flex flex-1 min-h-0">
          <%!-- Left sidebar --%>
          <div class="flex flex-col gap-2 p-2 bg-base-200 border-r border-base-300 w-28 overflow-y-auto">
            <button type="button" class="btn btn-sm btn-success">Begin turn</button>
            <button type="button" class="btn btn-sm btn-warning">Physical Damage</button>
            <button type="button" class="btn btn-sm btn-warning">Arcane Damage</button>
            <button type="button" class="btn btn-sm btn-success">Go Again</button>
            <div class="flex gap-1">
              <button type="button" class="btn btn-xs btn-warning flex-1">Dominate</button>
              <button type="button" class="btn btn-xs btn-warning flex-1">Overpower</button>
            </div>
            <button type="button" class="btn btn-sm btn-success">End turn</button>
            <div class="flex-1"></div>
            <button type="button" class="btn btn-sm">Card search</button>
            <div class="bg-warning text-warning-content rounded p-2 text-center">
              <div class="text-2xl font-bold">40</div>
              <div class="flex justify-center gap-2 text-sm">
                <button type="button" class="font-bold">+</button>
                <button type="button" class="font-bold">-</button>
              </div>
            </div>
          </div>

          <%!-- Central game area with canvas --%>
          <div class="flex-1 relative bg-blue-100">
            <canvas id="remote-canvas" class="w-full h-full"></canvas>
            <video id="remote-video" class="hidden" autoplay playsinline></video>

            <%!-- Waiting overlay --%>
            <div
              id="waiting-overlay"
              class="absolute inset-0 flex items-center justify-center bg-base-300/80"
            >
              <div class="text-center">
                <span class="loading loading-spinner loading-lg"></span>
                <p class="mt-2 text-lg">Waiting for opponent...</p>
              </div>
            </div>

            <%!-- Remote peer media status --%>
            <div id="remote-media-status" class="absolute top-2 right-2 flex gap-1 hidden">
              <div
                id="remote-camera-off"
                class="badge badge-error gap-1 hidden"
                title="Opponent's camera is off"
              >
                <.icon name="hero-video-camera-slash" class="size-3" /> Camera off
              </div>
              <div
                id="remote-mic-off"
                class="badge badge-error gap-1 hidden"
                title="Opponent is muted"
              >
                <.icon name="hero-microphone" class="size-3 opacity-50" /> Muted
              </div>
            </div>

            <%!-- Opponent life (bottom-right) --%>
            <div class="absolute bottom-2 right-2 bg-warning text-warning-content rounded p-2 text-center">
              <div class="text-2xl font-bold">36</div>
            </div>
          </div>
        </div>
      </div>

      <script :type={ColocatedHook} name=".GameVideo">
        import WebRTCManager from "@/js/webrtc.js"

        export default {
          mounted() {
            const gameId = this.el.dataset.gameId
            const token = this.el.dataset.userToken

            const localVideoEl = document.getElementById("local-video")
            const remoteVideoEl = document.getElementById("remote-video")
            const canvasEl = document.getElementById("remote-canvas")
            const statusEl = document.getElementById("connection-status")
            const waitingOverlay = document.getElementById("waiting-overlay")
            const toggleCameraBtn = document.getElementById("toggle-camera")
            const toggleMicBtn = document.getElementById("toggle-mic")

            const remoteStatusEl = document.getElementById("remote-media-status")
            const remoteCameraOff = document.getElementById("remote-camera-off")
            const remoteMicOff = document.getElementById("remote-mic-off")

            const updateButtonIcons = (btn, enabled) => {
              const on = btn.querySelector(".icon-on")
              const off = btn.querySelector(".icon-off")
              if (on) on.classList.toggle("hidden", !enabled)
              if (off) off.classList.toggle("hidden", enabled)
              btn.classList.toggle("btn-error", !enabled)
            }

            this.webrtc = new WebRTCManager({
              token,
              gameId,
              localVideoEl,
              remoteVideoEl,
              canvasEl,
              onStatusChange: (status) => {
                const labels = {
                  connecting: "Connecting...",
                  waiting: "Waiting for opponent...",
                  connected: "Connected",
                  disconnected: "Disconnected",
                  no_camera: "No camera",
                  error: "Error",
                }
                statusEl.textContent = labels[status] || status

                const badgeClass = {
                  connected: "badge-success",
                  disconnected: "badge-error",
                  error: "badge-error",
                  no_camera: "badge-warning",
                }
                statusEl.className = `badge badge-sm ${badgeClass[status] || "badge-outline"}`

                waitingOverlay.style.display = status === "connected" ? "none" : "flex"

                if (status === "waiting" || status === "disconnected") {
                  remoteStatusEl.classList.add("hidden")
                }
              },
              onRemoteMediaStatus: ({ camera, mic }) => {
                const anyOff = !camera || !mic
                remoteStatusEl.classList.toggle("hidden", !anyOff)
                remoteCameraOff.classList.toggle("hidden", camera)
                remoteMicOff.classList.toggle("hidden", mic)
              },
            })

            this.webrtc.start()

            this.el.addEventListener("click", (e) => {
              const btn = e.target.closest("#toggle-camera, #toggle-mic")
              if (!btn) return

              if (btn.id === "toggle-camera") {
                const enabled = this.webrtc.toggleCamera()
                updateButtonIcons(btn, enabled)
              } else if (btn.id === "toggle-mic") {
                const enabled = this.webrtc.toggleMic()
                updateButtonIcons(btn, enabled)
              }
            })
          },

          destroyed() {
            if (this.webrtc) {
              this.webrtc.disconnect()
            }
          },
        }
      </script>
    </Layouts.game>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Games.subscribe_games(socket.assigns.current_scope)
    end

    game = Games.get_game!(socket.assigns.current_scope, id)
    user_token = Phoenix.Token.sign(socket, "user socket", socket.assigns.current_scope.user.id)

    {:ok,
     socket
     |> assign(:page_title, game.title)
     |> assign(:game, game)
     |> assign(:user_token, user_token)}
  end

  @impl true
  def handle_info(
        {:updated, %Tabletop.Games.Game{id: id} = game},
        %{assigns: %{game: %{id: id}}} = socket
      ) do
    {:noreply, assign(socket, :game, game)}
  end

  def handle_info(
        {:deleted, %Tabletop.Games.Game{id: id}},
        %{assigns: %{game: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "The current game was deleted.")
     |> push_navigate(to: ~p"/games")}
  end

  def handle_info({type, %Tabletop.Games.Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end
end
