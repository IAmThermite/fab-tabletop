defmodule TabletopWeb.GameLive.Form do
  use TabletopWeb, :live_view

  alias Tabletop.Games
  alias Tabletop.Games.Game

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage game records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="game-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:title]} type="text" label="Game Title" />
        <.input
          field={@form[:format]}
          type="select"
          label="Format"
          options={Game.format_options()}
        />
        <.input field={@form[:hero]} type="text" label="Hero" />
        <.input field={@form[:decklist]} type="text" label="Decklist" placeholder="https://fabrary.com/..." />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Game</.button>
          <.button navigate={return_path(@current_scope, "index", @game)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    game = Games.get_game!(socket.assigns.current_scope, id)

    socket
    |> assign(:page_title, "Edit Game")
    |> assign(:game, game)
    |> assign(:form, to_form(Games.change_game(socket.assigns.current_scope, game)))
  end

  @impl true
  def handle_event("validate", %{"game" => game_params}, socket) do
    changeset = Games.change_game(socket.assigns.current_scope, socket.assigns.game, game_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"game" => game_params}, socket) do
    save_game(socket, socket.assigns.live_action, game_params)
  end

  defp save_game(socket, :edit, game_params) do
    case Games.update_game(socket.assigns.current_scope, socket.assigns.game, game_params) do
      {:ok, game} ->
        {:noreply,
         socket
         |> put_flash(:info, "Game updated successfully")
         |> push_navigate(to: return_path(socket.assigns.current_scope, "show", game))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(_scope, "index", _game), do: ~p"/"
  defp return_path(_scope, "show", game), do: ~p"/games/#{game}"
end
