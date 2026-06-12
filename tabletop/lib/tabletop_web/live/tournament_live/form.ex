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
    |> reset_form()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    tournament = Tournaments.get_tournament!(id)

    socket
    |> assign(:page_title, "Edit Tournament")
    |> assign(:tournament, tournament)
    |> reset_form()
  end

  # Builds (or rebuilds) the form from the tournament's current values, seeding
  # the minutes field from the stored seconds, and clears any active preset.
  defp reset_form(socket) do
    tournament = socket.assigns.tournament
    minutes = div(tournament.round_duration_seconds || 0, 60)

    changeset =
      Tournaments.change_tournament(
        tournament,
        %{"round_duration_minutes" => minutes},
        socket.assigns.current_scope
      )

    socket
    |> assign(:active_preset, nil)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"tournament" => params}, socket) do
    changeset =
      Tournaments.change_tournament(
        socket.assigns.tournament,
        params,
        socket.assigns.current_scope
      )

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("apply_preset", %{"preset" => id}, socket) do
    case Tournament.preset(id) do
      nil ->
        {:noreply, socket}

      preset ->
        params = merge_preset(socket.assigns.form.params, preset, current_format(socket))

        changeset =
          Tournaments.change_tournament(
            socket.assigns.tournament,
            params,
            socket.assigns.current_scope
          )

        {:noreply,
         socket
         |> assign(:active_preset, id)
         |> assign(:form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply, reset_form(socket)}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  # Overlay a preset onto whatever the admin has already typed. Keep a name
  # they've entered; derive round duration from the selected format.
  defp merge_preset(params, preset, format) do
    name =
      case params["name"] do
        n when is_binary(n) and n != "" -> n
        _ -> preset.name
      end

    Map.merge(params, %{
      "name" => name,
      "swiss_rounds" => preset.swiss_rounds,
      "top_cut_size" => preset.top_cut_size,
      "max_players" => preset.max_players,
      "round_duration_minutes" => Tournament.default_duration_minutes_for(format)
    })
  end

  defp current_format(socket) do
    case socket.assigns.form.params["format"] do
      f when is_binary(f) and f != "" -> String.to_existing_atom(f)
      _ -> socket.assigns.tournament.format || :classic_constructed
    end
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
        <:subtitle>
          Configure tournament settings. You can open registration after creation.
        </:subtitle>
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

        <fieldset class="fieldset">
          <label class="fieldset-label">Presets</label>
          <div class="flex flex-wrap items-center gap-2">
            <button
              :for={preset <- Tournament.presets()}
              type="button"
              phx-click="apply_preset"
              phx-value-preset={preset.id}
              class={[
                "btn btn-sm",
                if(@active_preset == preset.id, do: "btn-primary", else: "btn-soft")
              ]}
            >
              {preset.label}
            </button>
            <button type="button" phx-click="reset" class="btn btn-sm btn-ghost">
              Reset
            </button>
          </div>
          <p class="label">
            Fills rounds, top cut and max players. Tweak any field afterwards.
          </p>
        </fieldset>

        <.input field={@form[:swiss_rounds]} type="number" label="Swiss rounds" min="1" max="12" />
        <.input
          field={@form[:top_cut_size]}
          type="select"
          label="Top cut"
          options={Tournament.cut_size_options()}
        />
        <.input
          field={@form[:round_duration_minutes]}
          type="number"
          label="Round duration (minutes)"
          min="1"
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
