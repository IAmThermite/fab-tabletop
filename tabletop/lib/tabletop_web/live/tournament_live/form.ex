defmodule TabletopWeb.TournamentLive.Form do
  use TabletopWeb, :live_view

  alias Tabletop.Tournaments
  alias Tabletop.Tournaments.Tournament

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    tournament = %Tournament{
      round_duration_seconds: Tournament.default_duration_for(:classic_constructed)
    }

    socket
    |> assign(:page_title, "New Tournament")
    |> assign(:tournament, tournament)
    |> assign(:form, to_form(Tournaments.change_tournament(tournament, %{}, socket.assigns.current_scope)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    tournament = Tournaments.get_tournament!(id)

    socket
    |> assign(:page_title, "Edit Tournament")
    |> assign(:tournament, tournament)
    |> assign(:form, to_form(Tournaments.change_tournament(tournament, %{}, socket.assigns.current_scope)))
  end

  @impl true
  def handle_event("validate", %{"tournament" => params}, socket) do
    changeset =
      Tournaments.change_tournament(socket.assigns.tournament, params, socket.assigns.current_scope)

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Tournaments.create_tournament(socket.assigns.current_scope, params) do
      {:ok, t} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tournament created.")
         |> push_navigate(to: ~p"/tournaments/#{t}/admin")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Tournaments.update_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament,
           params
         ) do
      {:ok, t} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tournament updated.")
         |> push_navigate(to: ~p"/tournaments/#{t}/admin")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle>Configure tournament settings. You can open registration after creation.</:subtitle>
      </.header>

      <.form for={@form} id="tournament-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <.input
          field={@form[:format]}
          type="select"
          label="Format"
          options={Tournament.format_options()}
        />
        <.input field={@form[:max_players]} type="number" label="Max players" min="2" />
        <.input field={@form[:swiss_rounds]} type="number" label="Swiss rounds" min="1" max="12" />
        <.input
          field={@form[:top_cut_size]}
          type="select"
          label="Top cut"
          options={Tournament.cut_size_options()}
        />
        <.input
          field={@form[:round_duration_seconds]}
          type="number"
          label="Round duration (seconds)"
          min="60"
        />
        <.input field={@form[:starts_at]} type="datetime-local" label="Starts at" />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save</.button>
          <.button navigate={~p"/tournaments"}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end
end
