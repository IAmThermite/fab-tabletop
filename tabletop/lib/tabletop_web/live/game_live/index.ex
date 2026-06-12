defmodule TabletopWeb.GameLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts
  alias Tabletop.Accounts.Scope
  alias Tabletop.Games
  alias Tabletop.Games.Game
  alias Tabletop.Languages

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-7xl">
      <div id="game-index" phx-hook=".GameIndex">
        <.notice_banner
          id="camera-setup-banner"
          phx-update="ignore"
          class="hidden mb-6"
          title="Camera Setup Required"
          body="Set up your camera before joining or creating a game."
        >
          <:action>
            <.link navigate={~p"/camera-setup"} class="btn btn-warning btn-sm">Set Up Camera</.link>
          </:action>
        </.notice_banner>

        <.notice_banner
          :if={@current_scope && is_nil(@current_scope.user.confirmed_at)}
          class="mb-6"
          title="Email Confirmation Required"
          body="Please confirm your email address to create or join games."
        >
          <:action>
            <button phx-click="resend_confirmation" class="btn btn-warning btn-sm">
              Resend Confirmation Email
            </button>
          </:action>
        </.notice_banner>

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

            <p :if={!@current_scope} class="text-zinc-500 mb-3">
              <.link navigate={~p"/users/log-in"} class="text-blue-600 underline">Log in</.link>
              to join a game.
            </p>

            <%!-- Language filter (multi-select; no selection = show all) --%>
            <div class="flex flex-wrap items-center gap-2 mb-4">
              <span class="text-sm text-zinc-500">Language:</span>
              <button
                :for={{label, key} <- Languages.options()}
                type="button"
                phx-click="toggle_language_filter"
                phx-value-lang={key}
                aria-pressed={MapSet.member?(@language_filter, key)}
                class={[
                  "badge badge-sm cursor-pointer",
                  if(MapSet.member?(@language_filter, key),
                    do: "badge-primary",
                    else: "badge-outline"
                  )
                ]}
              >
                {label}
              </button>
              <button
                :if={MapSet.size(@language_filter) > 0}
                type="button"
                phx-click="clear_language_filter"
                class="text-xs text-zinc-500 underline ml-1"
              >
                Clear
              </button>
            </div>

            <div class="space-y-3">
              <details
                :for={{format, games} <- @grouped_games}
                :if={games != []}
                open={format == :classic_constructed}
                class="border border-zinc-200 dark:border-zinc-700 rounded-lg"
              >
                <summary class="flex items-center justify-between p-3 cursor-pointer font-semibold select-none">
                  <span>{Game.format_name_for(format)}</span>
                  <span class="badge badge-sm badge-neutral">{length(games)}</span>
                </summary>
                <div class="px-3 pb-3 space-y-2">
                  <div
                    :for={game <- games}
                    class="flex items-center justify-between gap-3 border border-zinc-200 dark:border-zinc-700 rounded-lg p-3"
                  >
                    <div class="min-w-0">
                      <div class="flex items-center gap-2">
                        <span class="truncate font-medium">{game.title}</span>
                        <span :if={game.user} class="text-sm text-zinc-500 shrink-0">
                          {game.user.name}
                        </span>
                        <span class="text-xs text-zinc-400 shrink-0">
                          · {Languages.name(game.language)}
                        </span>
                      </div>
                      <div
                        :if={present?(game.hero) || present?(game.decklist)}
                        class="flex items-center gap-2 mt-1"
                      >
                        <span :if={present?(game.hero)} class="badge badge-sm badge-outline">
                          {game.hero}
                        </span>
                        <.link
                          :if={present?(game.decklist)}
                          href={game.decklist}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="text-xs text-blue-600 underline"
                        >
                          Decklist ↗
                        </.link>
                      </div>
                    </div>
                    <.button
                      :if={@current_scope}
                      phx-click="join"
                      phx-value-id={game.id}
                      phx-disable-with="Joining…"
                      variant="primary"
                    >
                      JOIN
                    </.button>
                  </div>
                </div>
              </details>

              <p :if={!@any_games?} class="text-sm text-zinc-500 py-1">
                No open games right now — create one to get started.
              </p>
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
                <.input
                  field={@form[:language]}
                  type="select"
                  label="Language"
                  options={Languages.options()}
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

          <%!-- Open games --%>
          <div>
            <h2 class="text-2xl font-bold mb-4">Open games</h2>

            <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-4">
              <div class="flex items-baseline gap-2">
                <span class="text-3xl font-bold">{@open_games_count}</span>
                <span class="text-zinc-600 dark:text-zinc-400">
                  {if @open_games_count == 1,
                    do: "game waiting for an opponent",
                    else: "games waiting for an opponent"}
                </span>
              </div>
              <p class="mt-3 text-zinc-600 dark:text-zinc-400">
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
              label="Game code or link"
              placeholder="Paste a game code or link"
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
      |> assign(:language_filter, MapSet.new())
      |> assign_form(scope)
      |> assign_current_game(scope)
      |> assign_games()

    {:ok, socket}
  end

  defp assign_form(socket, %Scope{} = scope) do
    # Auto-fill the game language from the user's preference when they have one.
    game = %Game{user_id: scope.user.id, language: scope.user.language || Languages.default()}

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

  def handle_event("toggle_language_filter", %{"lang" => lang}, socket) do
    # Safe: language keys are compile-time atoms defined in Tabletop.Languages.
    lang = String.to_existing_atom(lang)
    filter = socket.assigns.language_filter

    filter =
      if MapSet.member?(filter, lang),
        do: MapSet.delete(filter, lang),
        else: MapSet.put(filter, lang)

    {:noreply, socket |> assign(:language_filter, filter) |> assign_games()}
  end

  def handle_event("clear_language_filter", _params, socket) do
    {:noreply, socket |> assign(:language_filter, MapSet.new()) |> assign_games()}
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
      case Games.get_joinable_game_by_code(extract_game_code(code)) do
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
    filter = socket.assigns.language_filter

    all_games = Games.list_joinable_games(scope)

    # No languages selected = show all; otherwise keep only matching languages.
    games =
      if MapSet.size(filter) == 0,
        do: all_games,
        else: Enum.filter(all_games, &MapSet.member?(filter, &1.language))

    grouped =
      Enum.group_by(games, & &1.format)
      |> then(fn grouped ->
        for {_label, format} <- Game.format_options(), into: [] do
          {format, Map.get(grouped, format, [])}
        end
      end)

    socket
    |> assign(:grouped_games, grouped)
    |> assign(:open_games_count, length(all_games))
    |> assign(:any_games?, games != [])
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Accepts a bare game code or a pasted game URL (e.g. ".../games/<id>" or
  # ".../games/<id>/pre-join") and returns the embedded UUID when present,
  # otherwise the trimmed input (which the lookup will reject as invalid).
  defp extract_game_code(input) do
    trimmed = String.trim(input || "")
    uuid = ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

    case Regex.run(uuid, trimmed) do
      [match | _] -> match
      nil -> trimmed
    end
  end
end
