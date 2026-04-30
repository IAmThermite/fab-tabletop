defmodule TabletopWeb.TournamentLive.Admin do
  use TabletopWeb, :live_view

  alias Tabletop.Tournaments
  alias Tabletop.Tournaments.{Tournament, TournamentMatch}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Tournaments.subscribe_tournament(id)
    {:ok, load(socket, id)}
  end

  @impl true
  def handle_info({:tournament_updated, id}, socket) do
    {:noreply, load(socket, id)}
  end

  defp load(socket, id) do
    t = Tournaments.get_tournament!(id)
    registrations = Tournaments.list_registrations(id)

    current_matches =
      case t.current_round_id do
        nil -> []
        round_id -> Tournaments.list_matches_for_round(round_id)
      end

    socket
    |> assign(:page_title, "Admin · " <> t.name)
    |> assign(:tournament, t)
    |> assign(:registrations, registrations)
    |> assign(:current_matches, current_matches)
    |> assign(:round_complete, Tournaments.current_round_complete?(t))
    |> assign(:completed_rounds, Tournaments.completed_round_count(t))
  end

  @impl true
  def handle_event("open_registration", _, socket) do
    with_result(socket, fn ->
      Tournaments.open_registration(socket.assigns.current_scope, socket.assigns.tournament)
    end)
  end

  def handle_event("start", _, socket) do
    with_result(socket, fn ->
      Tournaments.start_tournament(socket.assigns.current_scope, socket.assigns.tournament)
    end)
  end

  def handle_event("next_swiss", _, socket) do
    with_result(socket, fn ->
      Tournaments.generate_next_swiss_round(
        socket.assigns.current_scope,
        socket.assigns.tournament
      )
    end)
  end

  def handle_event("generate_cut", _, socket) do
    with_result(socket, fn ->
      Tournaments.generate_top_cut(socket.assigns.current_scope, socket.assigns.tournament)
    end)
  end

  def handle_event("advance_bracket", _, socket) do
    with_result(socket, fn ->
      Tournaments.advance_bracket(socket.assigns.current_scope, socket.assigns.tournament)
    end)
  end

  def handle_event("confirm_match", %{"id" => id}, socket) do
    with_result(socket, fn ->
      Tournaments.confirm_match(socket.assigns.current_scope, id)
    end)
  end

  def handle_event("override_match", %{"id" => id, "result" => result}, socket) do
    with_result(socket, fn ->
      Tournaments.override_match(socket.assigns.current_scope, id, result)
    end)
  end

  def handle_event("extend", %{"minutes" => m}, socket) do
    with_result(socket, fn ->
      Tournaments.extend_round(
        socket.assigns.current_scope,
        socket.assigns.tournament.current_round_id,
        String.to_integer(m) * 60
      )
    end)
  end

  def handle_event("drop_player", %{"user_id" => uid}, socket) do
    with_result(socket, fn ->
      Tournaments.admin_drop_player(
        socket.assigns.current_scope,
        socket.assigns.tournament.id,
        uid
      )
    end)
  end

  def handle_event("remove_player", %{"user_id" => uid}, socket) do
    with_result(socket, fn ->
      Tournaments.remove_registration(
        socket.assigns.current_scope,
        socket.assigns.tournament.id,
        uid
      )
    end)
  end

  def handle_event("cancel", _, socket) do
    with_result(socket, fn ->
      Tournaments.cancel_tournament(socket.assigns.current_scope, socket.assigns.tournament)
    end)
  end

  defp with_result(socket, fun) do
    case fun.() do
      {:ok, _} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  defp human_error(:not_enough_players), do: "Need at least 2 registered players to start."
  defp human_error(:round_incomplete), do: "Round is not fully confirmed yet."
  defp human_error(:wrong_status), do: "Can't do that in the current tournament status."
  defp human_error(:swiss_complete), do: "All swiss rounds completed — generate the top cut next."
  defp human_error(:reports_disagree), do: "Player reports disagree — use override."
  defp human_error(:tournament_started), do: "Tournament has already started — use drop instead."
  defp human_error(:not_registered), do: "That player isn't registered."
  defp human_error(_), do: "Something went wrong."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Admin · {@tournament.name}
        <:subtitle>{Tournament.format_name(@tournament)} · {@tournament.status}</:subtitle>
        <:actions>
          <.button navigate={~p"/tournaments/#{@tournament}/edit"}>Edit</.button>
          <.button navigate={~p"/tournaments/#{@tournament}"}>View</.button>
        </:actions>
      </.header>

      <.phase_controls
        tournament={@tournament}
        round_complete={@round_complete}
        completed_rounds={@completed_rounds}
      />

      <.round_panel :if={@current_matches != []} matches={@current_matches} tournament={@tournament} />

      <section class="my-6">
        <h2 class="font-semibold text-lg mb-2">
          Registered players ({length(@registrations)})
        </h2>
        <ul class="divide-y divide-base-300">
          <li :for={r <- @registrations} class="py-2 flex justify-between items-center">
            <div>
              <strong>{r.user && r.user.name}</strong>
              <span :if={r.hero} class="opacity-70 ml-2">{r.hero}</span>
              <a
                :if={r.decklist_url}
                class="link ml-2 text-sm"
                href={r.decklist_url}
                target="_blank"
                rel="noopener"
              >
                deck
              </a>
              <span :if={r.dropped_at} class="badge badge-ghost ml-2">dropped</span>
            </div>
            <div>
              <.button
                :if={@tournament.status in [:draft, :registration]}
                phx-click="remove_player"
                phx-value-user_id={r.user_id}
                data-confirm="Remove this player from the tournament?"
              >
                Remove
              </.button>
              <.button
                :if={@tournament.status not in [:draft, :registration] and is_nil(r.dropped_at)}
                phx-click="drop_player"
                phx-value-user_id={r.user_id}
                data-confirm="Drop this player?"
              >
                Drop
              </.button>
            </div>
          </li>
        </ul>
      </section>

      <section class="my-6">
        <.button phx-click="cancel" data-confirm="Cancel this tournament?">
          Cancel tournament
        </.button>
      </section>
    </Layouts.app>
    """
  end

  attr :tournament, :any, required: true
  attr :round_complete, :boolean, required: true
  attr :completed_rounds, :integer, required: true

  defp phase_controls(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 my-4">
      <h2 class="font-semibold text-lg mb-2">Phase</h2>

      <div :if={@tournament.status == :draft}>
        <.button variant="primary" phx-click="open_registration">Open registration</.button>
      </div>

      <div :if={@tournament.status == :registration}>
        <.button variant="primary" phx-click="start" data-confirm="Start the tournament?">
          Start tournament
        </.button>
      </div>

      <div :if={@tournament.status == :swiss} class="flex gap-2 flex-wrap">
        <.button
          :if={@round_complete and @completed_rounds < @tournament.swiss_rounds}
          variant="primary"
          phx-click="next_swiss"
        >
          Generate next swiss round ({@completed_rounds + 1}/{@tournament.swiss_rounds})
        </.button>
        <.button
          :if={
            @round_complete and @completed_rounds >= @tournament.swiss_rounds and
              @tournament.top_cut_size > 0
          }
          variant="primary"
          phx-click="generate_cut"
        >
          Generate top cut
        </.button>
        <.button
          :if={
            @round_complete and @completed_rounds >= @tournament.swiss_rounds and
              @tournament.top_cut_size in [0, nil]
          }
          variant="primary"
          phx-click="generate_cut"
          data-confirm="Finish the tournament based on current standings?"
        >
          Finish tournament
        </.button>
        <.button
          :if={@tournament.current_round_id}
          phx-click="extend"
          phx-value-minutes="10"
        >
          +10 minutes
        </.button>
      </div>

      <div :if={@tournament.status == :cut} class="flex gap-2">
        <.button :if={@round_complete} variant="primary" phx-click="advance_bracket">
          Advance bracket
        </.button>
        <.button
          :if={@tournament.current_round_id}
          phx-click="extend"
          phx-value-minutes="10"
        >
          +10 minutes
        </.button>
      </div>

      <div :if={@tournament.status == :finished} class="opacity-70">
        Tournament finished. Winner ID: {@tournament.winner_id}
      </div>
    </section>
    """
  end

  attr :matches, :list, required: true
  attr :tournament, :any, required: true

  defp round_panel(assigns) do
    ~H"""
    <section class="my-6">
      <h2 class="font-semibold text-lg mb-2">Current round matches</h2>
      <ul class="divide-y divide-base-300">
        <li :for={m <- @matches} class="py-3 flex justify-between items-center gap-4">
          <div>
            <div class="text-sm opacity-70">Table {m.table_number}</div>
            <div>
              <strong>{m.player1 && m.player1.name}</strong>
              vs
              <strong>
                {(m.player2 && m.player2.name) || "(bye)"}
              </strong>
            </div>
            <div class="text-sm">
              P1: {m.player1_reported || "—"} · P2: {m.player2_reported || "—"}
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span :if={m.confirmed_result} class="badge badge-success">
              {TournamentMatch.result_description(m.confirmed_result)}
            </span>
            <.button
              :if={
                is_nil(m.confirmed_result) and m.player1_reported &&
                  m.player1_reported == m.player2_reported
              }
              variant="primary"
              phx-click="confirm_match"
              phx-value-id={m.id}
            >
              Confirm
            </.button>
            <.override_menu :if={not TournamentMatch.bye?(m)} match={m} />
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :match, :any, required: true

  defp override_menu(assigns) do
    ~H"""
    <details class="dropdown dropdown-end">
      <summary class="btn btn-sm">{if @match.confirmed_result, do: "Change", else: "Override"}</summary>
      <ul class="menu dropdown-content bg-base-100 rounded-box shadow z-10 w-40">
        <li>
          <button phx-click="override_match" phx-value-id={@match.id} phx-value-result="p1_win">
            P1 wins
          </button>
        </li>
        <li>
          <button phx-click="override_match" phx-value-id={@match.id} phx-value-result="p2_win">
            P2 wins
          </button>
        </li>
        <li>
          <button phx-click="override_match" phx-value-id={@match.id} phx-value-result="draw">
            Draw
          </button>
        </li>
        <li>
          <button
            phx-click="override_match"
            phx-value-id={@match.id}
            phx-value-result="double_loss"
          >
            Double loss
          </button>
        </li>
      </ul>
    </details>
    """
  end
end
