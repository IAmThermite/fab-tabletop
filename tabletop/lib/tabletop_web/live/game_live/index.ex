defmodule TabletopWeb.GameLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts
  alias Tabletop.Accounts.Scope
  alias Tabletop.Games
  alias Tabletop.Games.Game
  alias Tabletop.Heroes
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
                class="btn btn-sm btn-success"
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
                    <div class="flex items-center gap-3 min-w-0">
                      <img
                        :if={Heroes.known?(game.hero)}
                        src={Heroes.icon_path(game.hero)}
                        alt={Heroes.name(game.hero)}
                        class="w-10 h-10 rounded-full shrink-0 bg-base-200"
                      />
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
                            {Heroes.name(game.hero) || game.hero}
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

              <p :if={!@any_games?} class="text-lg text-zinc-500 py-1">
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
              <button
                :if={@last_game}
                type="button"
                phx-click="quick_match"
                class="btn btn-sm btn-outline w-full mb-4"
              >
                ⚡ Quick match — reuse last game
              </button>

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
                <div>
                  <.input
                    field={@form[:hero]}
                    type="select"
                    label="Hero"
                    prompt="— Select hero —"
                    options={@hero_options}
                  />
                  <div :if={Heroes.known?(@form[:hero].value)} class="flex items-center gap-2 mt-2">
                    <img
                      src={Heroes.icon_path(@form[:hero].value)}
                      alt={Heroes.name(@form[:hero].value)}
                      class="w-12 h-12 rounded-full bg-base-200"
                    />
                    <span class="text-sm text-zinc-500">{Heroes.name(@form[:hero].value)}</span>
                  </div>
                </div>
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
                <div class="pt-4">
                  <.button class="btn btn-primary w-full" phx-disable-with="Starting...">
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

          <%!-- Live activity --%>
          <div>
            <h2 class="text-2xl font-bold mb-4">Live activity</h2>

            <div class="space-y-4">
              <%!-- Open games, broken down by format --%>
              <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-4">
                <div class="flex items-baseline gap-2">
                  <span class="text-3xl font-bold">{@activity.open_total}</span>
                  <span class="text-zinc-600 dark:text-zinc-400">
                    {if @activity.open_total == 1,
                      do: "game waiting for an opponent",
                      else: "games waiting for an opponent"}
                  </span>
                </div>

                <div :if={@activity.open_total > 0} class="mt-3 space-y-1.5">
                  <div
                    :for={{label, format} <- Game.format_options()}
                    :if={Map.get(@activity.open_by_format, format, 0) > 0}
                    class="flex items-center justify-between text-sm"
                  >
                    <span class="text-zinc-600 dark:text-zinc-400">{label}</span>
                    <span class="badge badge-sm badge-neutral">
                      {Map.get(@activity.open_by_format, format, 0)}
                    </span>
                  </div>
                </div>

                <p :if={@activity.open_total == 0} class="mt-3 text-zinc-600 dark:text-zinc-400">
                  Create or join a game of Flesh and Blood to get started.
                  Set up your hero, share your decklist, and battle your opponent with live video chat.
                </p>
              </div>

              <%!-- Players in game / games in progress --%>
              <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-4">
                <div class="grid grid-cols-2 gap-4 text-center">
                  <div>
                    <div class="text-3xl font-bold">{@activity.active_games}</div>
                    <div class="text-sm text-zinc-600 dark:text-zinc-400">
                      {if @activity.active_games == 1,
                        do: "game in progress",
                        else: "games in progress"}
                    </div>
                  </div>
                  <div>
                    <div class="flex items-center justify-center gap-2">
                      <span
                        :if={@activity.active_players > 0}
                        class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"
                      />
                      <span class="text-3xl font-bold">{@activity.active_players}</span>
                    </div>
                    <div class="text-sm text-zinc-600 dark:text-zinc-400">
                      {if @activity.active_players == 1,
                        do: "player in a game",
                        else: "players in a game"}
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Popular heroes by format, last 7 days --%>
              <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-4">
                <h3 class="font-semibold mb-3">
                  Popular heroes <span class="text-xs font-normal text-zinc-500">· last 7 days</span>
                </h3>

                <div :if={@popular_heroes_any?} class="space-y-3">
                  <div
                    :for={{label, format} <- Game.format_options()}
                    :if={Map.get(@activity.popular_heroes, format, []) != []}
                  >
                    <div class="text-xs uppercase tracking-wide text-zinc-500 mb-1.5">
                      {label}
                    </div>
                    <div class="space-y-1.5">
                      <div
                        :for={{hero, count} <- Map.get(@activity.popular_heroes, format, [])}
                        class="flex items-center gap-2"
                      >
                        <img
                          :if={Heroes.known?(hero)}
                          src={Heroes.icon_path(hero)}
                          alt={Heroes.name(hero)}
                          class="w-6 h-6 rounded-full bg-base-200 shrink-0"
                        />
                        <span class="text-sm truncate">{Heroes.name(hero) || hero}</span>
                        <span class="ml-auto text-xs text-zinc-500">{count}</span>
                      </div>
                    </div>
                  </div>
                </div>

                <p :if={!@popular_heroes_any?} class="text-sm text-zinc-500">
                  No heroes chosen yet this week.
                </p>
              </div>

              <%!-- Tournaments land here once events ship --%>
              <div class="border border-dashed border-zinc-300 dark:border-zinc-700 rounded-lg p-4 text-center">
                <div class="text-sm font-semibold text-zinc-600 dark:text-zinc-400">Tournaments</div>
                <div class="text-xs text-zinc-500 mt-1">Coming soon</div>
              </div>
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
      |> assign_last_game(scope)
      |> assign_games()
      |> assign_activity()

    {:ok, socket}
  end

  defp assign_form(socket, %Scope{} = scope) do
    # Auto-fill the game language from the user's preference when they have one.
    game = %Game{user_id: scope.user.id, language: scope.user.language || Languages.default()}

    socket
    |> assign(:game, game)
    |> assign(:hero_options, Heroes.options_for(game.format))
    |> assign(:form, to_form(Games.change_game(scope, game)))
  end

  defp assign_form(socket, nil) do
    socket
    |> assign(:game, nil)
    |> assign(:hero_options, [])
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("validate", %{"game" => game_params}, socket) do
    format = parse_format(game_params["format"], socket.assigns.game.format)
    hero_options = Heroes.options_for(format)
    game_params = drop_illegal_hero(game_params, hero_options)

    changeset =
      Games.change_game(socket.assigns.current_scope, socket.assigns.game, game_params)

    {:noreply,
     socket
     |> assign(:hero_options, hero_options)
     |> assign(form: to_form(changeset, action: :validate))}
  end

  # Seed the create form from the user's last game so they can rematch with one
  # extra click. We only fill the form — the user still presses Start to create.
  def handle_event("quick_match", _params, socket) do
    case socket.assigns.last_game do
      nil ->
        {:noreply, socket}

      last ->
        scope = socket.assigns.current_scope

        game = %Game{
          user_id: scope.user.id,
          format: last.format,
          language: last.language,
          title: last.title,
          hero: last.hero,
          decklist: last.decklist
        }

        {:noreply,
         socket
         |> assign(:game, game)
         |> assign(:hero_options, Heroes.options_for(game.format))
         |> assign(:form, to_form(Games.change_game(scope, game)))}
    end
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
     |> assign_last_game(socket.assigns.current_scope)
     |> assign_games()
     |> assign_activity()}
  end

  defp assign_current_game(socket, %Scope{} = scope) do
    assign(socket, :current_game, Games.get_current_game_for_user(scope))
  end

  defp assign_current_game(socket, nil) do
    assign(socket, :current_game, nil)
  end

  defp assign_last_game(socket, scope) do
    assign(socket, :last_game, Games.get_last_created_game(scope))
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
    |> assign(:any_games?, games != [])
  end

  defp assign_activity(socket) do
    activity = Games.activity_stats()

    popular_heroes_any? =
      Enum.any?(activity.popular_heroes, fn {_format, heroes} -> heroes != [] end)

    socket
    |> assign(:activity, activity)
    |> assign(:popular_heroes_any?, popular_heroes_any?)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Resolve the format param (a string) to its atom, falling back to the
  # current game's format when absent or unrecognised.
  defp parse_format(nil, fallback), do: fallback

  defp parse_format(param, fallback) do
    case Enum.find(Game.format_options(), fn {_label, key} -> to_string(key) == param end) do
      {_label, key} -> key
      nil -> fallback
    end
  end

  # Clear the chosen hero when it isn't legal in the (possibly just-changed)
  # format, so the dropdown never shows a stale, illegal selection.
  defp drop_illegal_hero(%{"hero" => hero} = params, hero_options)
       when is_binary(hero) and hero != "" do
    if Enum.any?(hero_options, fn {_name, slug} -> slug == hero end),
      do: params,
      else: Map.put(params, "hero", "")
  end

  defp drop_illegal_hero(params, _hero_options), do: params

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
