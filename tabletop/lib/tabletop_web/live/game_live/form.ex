defmodule TabletopWeb.GameLive.Form do
  use TabletopWeb, :live_view

  alias Tabletop.Games
  alias Tabletop.Games.Game
  alias Tabletop.Heroes

  on_mount {TabletopWeb.UserAuth, :require_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      system_announcement={@system_announcement}
    >
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
        <%!-- Language selector hidden for now (matches the lobby — revisit
             display/UX later). The value still submits via the hidden input so
             saving keeps the game's existing language. --%>
        <.input field={@form[:language]} type="hidden" />
        <%!--
        <.input
          field={@form[:language]}
          type="select"
          label="Language"
          options={Tabletop.Languages.options()}
        />
        --%>
        <.input
          field={@form[:hero]}
          type="select"
          label="Hero"
          prompt="— Select hero —"
          options={@hero_options}
        />
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
    |> assign(:hero_options, Heroes.options_for(game.format))
    |> assign(:form, to_form(Games.change_game(socket.assigns.current_scope, game)))
  end

  @impl true
  def handle_event("validate", %{"game" => game_params}, socket) do
    format = parse_format(game_params["format"], socket.assigns.game.format)
    hero_options = Heroes.options_for(format)
    game_params = drop_illegal_hero(game_params, hero_options)

    changeset = Games.change_game(socket.assigns.current_scope, socket.assigns.game, game_params)

    {:noreply,
     socket
     |> assign(:hero_options, hero_options)
     |> assign(form: to_form(changeset, action: :validate))}
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

  # Resolve the format param (a string) to its atom, falling back to the current
  # game's format when absent or unrecognised.
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
end
