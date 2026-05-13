defmodule TabletopWeb.GameLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts
  alias Tabletop.Accounts.Scope
  alias Tabletop.Games
  alias Tabletop.Games.Game

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-7xl">
      <div id="game-index" phx-hook=".GameIndex">
        <div
          id="camera-setup-banner"
          phx-update="ignore"
          class="hidden mb-6 border-2 border-warning rounded-lg p-4 bg-warning/10"
        >
          <div class="flex items-center justify-between">
            <div>
              <h3 class="font-bold">Camera Setup Required</h3>
              <p class="text-sm opacity-75">Set up your camera before joining or creating a game.</p>
            </div>
            <.link navigate={~p"/camera-setup"} class="btn btn-warning btn-sm">Set Up Camera</.link>
          </div>
        </div>

        <div
          :if={@current_scope && is_nil(@current_scope.user.confirmed_at)}
          class="mb-6 border-2 border-warning rounded-lg p-4 bg-warning/10"
        >
          <div class="flex items-center justify-between">
            <div>
              <h3 class="font-bold">Email Confirmation Required</h3>
              <p class="text-sm opacity-75">
                Please confirm your email address to create or join games.
              </p>
            </div>
            <button phx-click="resend_confirmation" class="btn btn-warning btn-sm">
              Resend Confirmation Email
            </button>
          </div>
        </div>

        <div
          :if={@current_game}
          class="mb-6 border-2 border-primary rounded-lg p-4 bg-primary/10"
        >
          <h2 class="text-xl font-bold mb-2">Game in Progress</h2>
          <div class="flex items-center justify-between">
            <div>
              <span class="font-semibold">{@current_game.title}</span>
              <span class="text-sm text-zinc-500 ml-2">
                {Game.format_name(@current_game)}
              </span>
            </div>
            <div class="flex gap-2">
              <.link navigate={~p"/games/#{@current_game}/pre-join"} class="btn btn-primary btn-sm">
                Rejoin Game
              </.link>
              <button
                phx-click="leave_game"
                phx-value-id={@current_game.id}
                data-confirm="Are you sure you want to leave the game?"
                class="btn btn-error btn-sm btn-outline"
              >
                Leave Game
              </button>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <%!-- Games to join --%>
          <div>
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-2xl font-bold">Games to join</h2>
              <button
                :if={@current_scope}
                type="button"
                phx-click="open_join_private"
                class="btn btn-sm btn-outline"
              >
                Join private
              </button>
            </div>

            <div class="space-y-3">
              <details
                :for={{format, games} <- @grouped_games}
                open={format == :classic_constructed}
                class="border border-zinc-200 dark:border-zinc-700 rounded-lg"
              >
                <summary class="flex items-center justify-between p-3 cursor-pointer font-semibold select-none">
                  <span>{Game.format_name_for(format)}</span>
                  <span class="text-sm font-normal text-zinc-500">
                    {length(games)}
                  </span>
                </summary>
                <div class="px-3 pb-3 space-y-2">
                  <div
                    :for={game <- games}
                    class="flex items-center justify-between border border-zinc-200 dark:border-zinc-700 rounded-lg p-3"
                  >
                    <span class="truncate">{game.title}</span>
                    <.button
                      :if={@current_scope}
                      phx-click="join"
                      phx-value-id={game.id}
                      variant="primary"
                    >
                      JOIN
                    </.button>
                  </div>
                  <p :if={games == []} class="text-sm text-zinc-500 py-1">
                    No games available
                  </p>
                </div>
              </details>
            </div>
          </div>

          <%!-- Create Game --%>
          <div>
            <h2 class="text-2xl font-bold mb-4">Create Game</h2>

            <div
              :if={@current_scope}
              class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-4"
            >
              <.form
                for={@form}
                id="create-game-form"
                phx-change="validate"
                phx-submit="create"
                class="space-y-4"
              >
                <.input
                  field={@form[:format]}
                  type="select"
                  label="Format"
                  options={Game.format_options()}
                />
                <.input field={@form[:title]} type="text" label="Game Title" />
                <.input field={@form[:hero]} type="text" label="Hero" />
                <.input
                  field={@form[:decklist]}
                  type="text"
                  label="Decklist"
                  placeholder="https://fabrary.com/..."
                />
                <.input
                  field={@form[:private]}
                  type="checkbox"
                  class="toggle"
                  label="Private game (won't appear in the public list)"
                />
                <div class="flex justify-center pt-4">
                  <.button variant="primary" phx-disable-with="Starting...">
                    Start
                  </.button>
                </div>
              </.form>
            </div>
            <p :if={!@current_scope} class="text-zinc-500">
              <.link navigate={~p"/users/log-in"} class="text-blue-600 underline">Log in</.link>
              to create a game.
            </p>
          </div>

          <%!-- News --%>
          <div>
            <h2 class="text-2xl font-bold mb-4">News</h2>

            <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-4">
              <h3 class="font-bold text-lg">Welcome to Fab Tabletop</h3>
              <p class="mt-2 text-zinc-600 dark:text-zinc-400">
                Create or join a game of Flesh and Blood to get started.
                Set up your hero, share your decklist, and battle your opponent with live video chat.
              </p>
            </div>
          </div>
        </div>
      </div>

      <dialog :if={@show_join_private} id="join-private-dialog" class="modal modal-open">
        <div class="modal-box">
          <h3 class="text-lg font-bold mb-4">Join private game</h3>
          <.form
            for={%{}}
            as={:join_private}
            phx-submit="join_private"
            class="space-y-3"
          >
            <.input
              name="code"
              value=""
              type="text"
              label="Game code"
              placeholder="e.g. 3f8a4b2c-1e7d-4f9a-9c5b-7e8d1f2a3c4d"
              autocomplete="off"
            />
            <div class="modal-action">
              <button type="button" phx-click="close_join_private" class="btn">
                Cancel
              </button>
              <.button variant="primary" type="submit">Join</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close_join_private"></div>
      </dialog>
    </Layouts.app>

    <script :type={ColocatedHook} name=".GameIndex">
      export default {
        mounted() {
          const setupDone = localStorage.getItem("tabletop:camera-setup-done") === "true"

          if (!setupDone) {
            const banner = document.getElementById("camera-setup-banner")
            if (banner) banner.classList.remove("hidden")
          }
        }
      }
    </script>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Games.subscribe_games(scope)
    end

    socket =
      socket
      |> assign(:page_title, "Games")
      |> assign(:show_join_private, false)
      |> assign_form(scope)
      |> assign_current_game(scope)
      |> assign_games()

    {:ok, socket}
  end

  defp assign_form(socket, %Scope{} = scope) do
    game = %Game{user_id: scope.user.id}

    socket
    |> assign(:game, game)
    |> assign(:form, to_form(Games.change_game(scope, game)))
  end

  defp assign_form(socket, nil) do
    socket
    |> assign(:game, nil)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("validate", %{"game" => game_params}, socket) do
    changeset =
      Games.change_game(socket.assigns.current_scope, socket.assigns.game, game_params)

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("create", %{"game" => game_params}, socket) do
    if is_nil(socket.assigns.current_scope.user.confirmed_at) do
      {:noreply,
       put_flash(socket, :error, "Please confirm your email address before creating a game.")}
    else
      case Games.create_game(socket.assigns.current_scope, game_params) do
        {:ok, %Game{private: true} = game} ->
          {:noreply,
           socket
           |> put_flash(:share_code, game.id)
           |> push_navigate(to: ~p"/games/#{game}/pre-join")}

        {:ok, game} ->
          {:noreply,
           socket
           |> put_flash(:info, "Game created successfully")
           |> push_navigate(to: ~p"/games/#{game}/pre-join")}

        {:error, :already_in_game} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "You're already in a game. Finish or leave it before creating another."
           )}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end
  end

  def handle_event("leave_game", %{"id" => id}, socket) do
    game = Games.get_game!(socket.assigns.current_scope, id)
    Games.LeaveTimer.cancel_leave(game.id, socket.assigns.current_scope.user.id)
    Games.terminate_game(socket.assigns.current_scope, game)
    {:noreply, assign_current_game(socket, socket.assigns.current_scope)}
  end

  def handle_event("resend_confirmation", _params, socket) do
    user = socket.assigns.current_scope.user

    if is_nil(user.confirmed_at) do
      Accounts.deliver_user_confirmation_instructions(
        user,
        &url(~p"/users/confirm/#{&1}")
      )

      {:noreply, put_flash(socket, :info, "Confirmation email sent. Please check your inbox.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("join", %{"id" => id}, socket) do
    if is_nil(socket.assigns.current_scope.user.confirmed_at) do
      {:noreply,
       put_flash(socket, :error, "Please confirm your email address before joining a game.")}
    else
      {:noreply, push_navigate(socket, to: ~p"/games/#{id}/pre-join")}
    end
  end

  def handle_event("open_join_private", _params, socket) do
    {:noreply, assign(socket, :show_join_private, true)}
  end

  def handle_event("close_join_private", _params, socket) do
    {:noreply, assign(socket, :show_join_private, false)}
  end

  def handle_event("join_private", %{"code" => code}, socket) do
    if is_nil(socket.assigns.current_scope.user.confirmed_at) do
      {:noreply,
       put_flash(socket, :error, "Please confirm your email address before joining a game.")}
    else
      case Games.get_joinable_game_by_code(code) do
        {:ok, game} ->
          {:noreply,
           socket
           |> assign(:show_join_private, false)
           |> push_navigate(to: ~p"/games/#{game}/pre-join")}

        {:error, :invalid_code} ->
          {:noreply, put_flash(socket, :error, "Invalid game code.")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Game not found or no longer available.")}
      end
    end
  end

  @impl true
  def handle_info({type, %Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     socket
     |> assign_current_game(socket.assigns.current_scope)
     |> assign_games()}
  end

  defp assign_current_game(socket, %Scope{} = scope) do
    assign(socket, :current_game, Games.get_current_game_for_user(scope))
  end

  defp assign_current_game(socket, nil) do
    assign(socket, :current_game, nil)
  end

  defp assign_games(socket) do
    scope = socket.assigns.current_scope

    games = Games.list_joinable_games(scope)

    grouped =
      Enum.group_by(games, & &1.format)
      |> then(fn grouped ->
        for {_label, format} <- Game.format_options(), into: [] do
          {format, Map.get(grouped, format, [])}
        end
      end)

    assign(socket, :grouped_games, grouped)
  end
end
