defmodule TabletopWeb.GameLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Accounts.Scope
  alias Tabletop.Games
  alias Tabletop.Games.Game

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-7xl">
      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <%!-- Games to join --%>
        <div>
          <h2 class="text-2xl font-bold mb-4">Games to join</h2>

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
              <div class="flex justify-center pt-4">
                <.button variant="primary" phx-disable-with="Starting...">Start</.button>
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
    </Layouts.app>
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
      |> assign_form(scope)
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
    case Games.create_game(socket.assigns.current_scope, game_params) do
      {:ok, game} ->
        {:noreply,
         socket
         |> put_flash(:info, "Game created successfully")
         |> push_navigate(to: ~p"/games/#{game}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("join", %{"id" => id}, socket) do
    game = Games.get_game!(socket.assigns.current_scope, id)

    case Games.join_game(socket.assigns.current_scope, game) do
      {:ok, game} ->
        {:noreply,
         socket
         |> put_flash(:info, "Joined game successfully")
         |> push_navigate(to: ~p"/games/#{game}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to join game")}
    end
  end

  @impl true
  def handle_info({type, %Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, assign_games(socket)}
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
