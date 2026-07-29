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

  # Fired once a start time gate (check-in minimum or scheduled start) passes,
  # so the "Start tournament" button can enable without another tournament update.
  def handle_info(:start_gate_ready, socket) do
    {:noreply, load(socket, socket.assigns.tournament.id)}
  end

  defp load(socket, id) do
    t = Tournaments.get_tournament!(id)
    registrations = Tournaments.list_registrations(id)

    active = Enum.reject(registrations, & &1.dropped_at)
    checked_in = Enum.count(active, & &1.checked_in_at)

    current_matches =
      case t.current_round_id do
        nil -> []
        round_id -> Tournaments.list_matches_for_round(round_id)
      end

    start_time_reached = Tournaments.start_time_reached?(t)
    check_in_min_elapsed = Tournaments.check_in_min_elapsed?(t)

    socket
    |> assign(:page_title, "Admin · " <> t.name)
    |> assign(:tournament, t)
    |> assign(:registrations, registrations)
    |> assign(:hero_by_user, Map.new(registrations, &{&1.user_id, &1.hero}))
    |> assign(:current_matches, current_matches)
    |> assign(:round_complete, Tournaments.current_round_complete?(t))
    |> assign(:completed_rounds, Tournaments.completed_round_count(t))
    |> assign(:active_count, length(active))
    |> assign(:checked_in_count, checked_in)
    |> assign(:start_time_reached, start_time_reached)
    |> assign(:check_in_min_elapsed, check_in_min_elapsed)
    |> assign(
      :can_start,
      t.status == :check_in and check_in_min_elapsed and start_time_reached
    )
    |> assign(:check_in_start_at, Tournaments.check_in_start_allowed_at(t))
    |> assign(:check_in_min_minutes, div(Tournaments.check_in_min_seconds(), 60))
    |> maybe_schedule_start_ready(t)
  end

  # While the tournament is in check-in, wake this LiveView up when the next
  # time gate (check-in minimum or scheduled start) passes, so the start button
  # can enable itself. Re-scheduling on each load cancels the prior timer to
  # avoid pile-up; on wake we reload and schedule the following gate, if any.
  defp maybe_schedule_start_ready(socket, t) do
    if socket.assigns[:start_gate_timer],
      do: Process.cancel_timer(socket.assigns.start_gate_timer)

    ref =
      if connected?(socket) and t.status == :check_in do
        case next_start_gate_at(t) do
          nil ->
            nil

          at ->
            ms = DateTime.diff(at, DateTime.utc_now(), :millisecond)
            Process.send_after(self(), :start_gate_ready, max(ms, 0) + 250)
        end
      end

    assign(socket, :start_gate_timer, ref)
  end

  # The soonest future time gate that could change whether start is allowed.
  defp next_start_gate_at(t) do
    now = DateTime.utc_now()

    [Tournaments.check_in_start_allowed_at(t), t.starts_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> case do
      [] -> nil
      times -> Enum.min(times, DateTime)
    end
  end

  @impl true
  def handle_event("open_registration", _, socket) do
    with_result(socket, fn ->
      Tournaments.open_registration(socket.assigns.current_scope, socket.assigns.tournament)
    end)
  end

  def handle_event("open_check_in", _, socket) do
    with_result(socket, fn ->
      Tournaments.open_check_in(socket.assigns.current_scope, socket.assigns.tournament)
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

  defp human_error(:not_enough_players), do: "Need at least 2 checked-in players to start."

  defp human_error(:check_in_too_soon),
    do: "Check-in must stay open for at least 5 minutes before starting."

  defp human_error(:before_start_time),
    do: "The tournament's scheduled start time hasn't passed yet."

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
        <:subtitle>
          {Tournament.format_name(@tournament)}
          <.tournament_status_badge status={@tournament.status} class="ml-1 align-middle" />
          <span :if={@tournament.starts_at}>
            · starts
            <.local_datetime
              id="tournament-starts-at"
              at={@tournament.starts_at}
              countdown={@tournament.status in [:draft, :registration]}
            />
          </span>
        </:subtitle>
        <:actions>
          <.button navigate={~p"/tournaments/#{@tournament}/edit"}>Edit</.button>
          <.button navigate={~p"/tournaments/#{@tournament}"}>View</.button>
        </:actions>
      </.header>

      <.phase_stepper tournament={@tournament} class="my-4 overflow-x-auto" />

      <.phase_controls
        tournament={@tournament}
        hero_by_user={@hero_by_user}
        round_complete={@round_complete}
        completed_rounds={@completed_rounds}
        active_count={@active_count}
        checked_in_count={@checked_in_count}
        can_start={@can_start}
        check_in_min_elapsed={@check_in_min_elapsed}
        start_time_reached={@start_time_reached}
        check_in_start_at={@check_in_start_at}
        check_in_min_minutes={@check_in_min_minutes}
      />

      <.round_panel
        :if={@current_matches != []}
        matches={@current_matches}
        tournament={@tournament}
        hero_by_user={@hero_by_user}
      />

      <section class="my-6">
        <h2 class="font-display text-lg font-bold mb-2">
          Registered players ({length(@registrations)})
        </h2>
        <ul class="divide-y divide-base-300 rounded-box border border-base-300 px-3">
          <li :for={r <- @registrations} class="py-2 flex justify-between items-center gap-3">
            <div class="flex items-center gap-2 min-w-0">
              <.hero_portrait hero={r.hero} class="size-8" />
              <div class="min-w-0">
                <strong>{r.user && r.user.name}</strong>
                <span :if={hero_name(r.hero)} class="opacity-70 ml-1 text-sm">
                  {hero_name(r.hero)}
                </span>
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
                <span
                  :if={@tournament.status == :check_in and is_nil(r.dropped_at) and r.checked_in_at}
                  class="badge badge-success ml-2"
                >
                  checked in
                </span>
                <span
                  :if={
                    @tournament.status == :check_in and is_nil(r.dropped_at) and
                      is_nil(r.checked_in_at)
                  }
                  class="badge badge-warning ml-2"
                >
                  not checked in
                </span>
              </div>
            </div>
            <div>
              <.button
                :if={@tournament.status in [:draft, :registration]}
                variant="danger"
                phx-click="remove_player"
                phx-value-user_id={r.user_id}
                data-confirm="Remove this player from the tournament?"
              >
                Remove
              </.button>
              <.button
                :if={@tournament.status not in [:draft, :registration] and is_nil(r.dropped_at)}
                variant="danger"
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

      <section
        :if={@tournament.status != :cancelled}
        class="my-6 rounded-box border border-error/40 p-4"
      >
        <h2 class="font-display text-base font-bold text-error mb-1">Danger zone</h2>
        <div class="flex items-center justify-between gap-3">
          <p class="text-sm text-base-content/70">
            Cancelling ends the tournament for everyone. This can't be undone.
          </p>
          <.button variant="danger" phx-click="cancel" data-confirm="Cancel this tournament?">
            Cancel tournament
          </.button>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :tournament, :any, required: true
  attr :hero_by_user, :map, required: true
  attr :round_complete, :boolean, required: true
  attr :completed_rounds, :integer, required: true
  attr :active_count, :integer, required: true
  attr :checked_in_count, :integer, required: true
  attr :can_start, :boolean, required: true
  attr :check_in_min_elapsed, :boolean, required: true
  attr :start_time_reached, :boolean, required: true
  attr :check_in_start_at, :any, required: true
  attr :check_in_min_minutes, :integer, required: true

  defp phase_controls(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 my-4">
      <h2 class="font-display text-lg font-bold mb-2">Phase</h2>

      <div :if={@tournament.status == :draft}>
        <.button variant="primary" phx-click="open_registration">Open registration</.button>
      </div>

      <div :if={@tournament.status == :registration} class="space-y-2">
        <.button
          variant="primary"
          phx-click="open_check_in"
          disabled={@active_count < 2}
          data-confirm="Open check-in? Sign-ups will close and players must check in to play."
        >
          Open check-in
        </.button>
        <p :if={@active_count < 2} class="text-sm opacity-70">
          Need at least 2 registered players to open check-in.
        </p>
      </div>

      <div :if={@tournament.status == :check_in} class="space-y-3">
        <p class="text-sm">
          <strong>{@checked_in_count}</strong>
          of {@active_count} players checked in.
          <span :if={@active_count - @checked_in_count > 0} class="text-warning">
            {@active_count - @checked_in_count} not checked in — they'll be dropped on start.
          </span>
        </p>

        <div class="flex gap-2 flex-wrap items-center">
          <.button
            variant="primary"
            phx-click="start"
            disabled={not @can_start or @checked_in_count < 2}
            data-confirm="Start the tournament? Players who haven't checked in will be dropped."
          >
            Start tournament
          </.button>
          <.button
            phx-click="open_registration"
            data-confirm="Reopen registration? This closes check-in and clears check-ins."
          >
            Reopen registration
          </.button>
        </div>

        <p :if={@checked_in_count < 2} class="text-sm opacity-70">
          Need at least 2 checked-in players to start.
        </p>

        <p :if={not @check_in_min_elapsed and @check_in_start_at} class="text-sm opacity-70">
          Check-in must stay open for {@check_in_min_minutes} minutes — available
          <.local_datetime id="check-in-start-at" at={@check_in_start_at} countdown />
        </p>

        <p :if={not @start_time_reached and @tournament.starts_at} class="text-sm opacity-70">
          Scheduled start hasn't arrived — start available
          <.local_datetime id="scheduled-start-at" at={@tournament.starts_at} countdown />
        </p>
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

      <div :if={@tournament.status == :finished} class="space-y-2">
        <div class="text-sm text-base-content/70">Tournament finished. Champion:</div>
        <.player_identity
          :if={@tournament.winner}
          user={@tournament.winner}
          hero={Map.get(@hero_by_user, @tournament.winner_id)}
          portrait_class="size-10"
        />
        <div :if={is_nil(@tournament.winner)} class="opacity-70">No champion recorded.</div>
      </div>
    </section>
    """
  end

  attr :matches, :list, required: true
  attr :tournament, :any, required: true
  attr :hero_by_user, :map, required: true

  defp round_panel(assigns) do
    ~H"""
    <section class="my-6">
      <h2 class="font-display text-lg font-bold mb-2">Current round matches</h2>
      <.round_timer
        :if={@tournament.status not in [:finished, :cancelled]}
        round={@tournament.current_round}
        class="mb-4 max-w-sm"
      />
      <ul class="divide-y divide-base-300">
        <li :for={m <- @matches} class="py-3 flex justify-between items-center gap-4">
          <div class="min-w-0">
            <div class="text-sm opacity-70">Table {m.table_number}</div>
            <div>
              <strong>{m.player1 && m.player1.name}</strong>
              vs <strong>{(m.player2 && m.player2.name) || "(bye)"}</strong>
            </div>
            <div :if={is_nil(m.confirmed_result)} class="text-sm text-base-content/60">
              {m.player1 && m.player1.name} reported:
              <span class="font-medium">{report_text(m, m.player1_reported)}</span>
              · {m.player2 && m.player2.name} reported:
              <span class="font-medium">{report_text(m, m.player2_reported)}</span>
            </div>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <.match_result
              :if={m.confirmed_result}
              match={m}
              result={m.confirmed_result}
              hero_by_user={@hero_by_user}
              class="text-sm text-success text-right"
            />
            <.button
              :if={
                (is_nil(m.confirmed_result) and m.player1_reported) &&
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

  # A player's report as a name-based label, or "—" when they haven't reported.
  defp report_text(_match, nil), do: "—"
  defp report_text(match, result), do: match_result_text(match, result)

  attr :match, :any, required: true

  defp override_menu(assigns) do
    ~H"""
    <details class="dropdown dropdown-end">
      <summary class="btn btn-sm">
        {if @match.confirmed_result, do: "Change", else: "Override"}
      </summary>
      <ul class="menu dropdown-content bg-base-100 rounded-box shadow z-10 w-56">
        <li>
          <button phx-click="override_match" phx-value-id={@match.id} phx-value-result="p1_win">
            {@match.player1 && @match.player1.name} wins
          </button>
        </li>
        <li>
          <button phx-click="override_match" phx-value-id={@match.id} phx-value-result="p2_win">
            {@match.player2 && @match.player2.name} wins
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
