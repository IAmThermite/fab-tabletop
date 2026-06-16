defmodule TabletopWeb.TournamentLive.Show do
  use TabletopWeb, :live_view

  alias Tabletop.Tournaments
  alias Tabletop.Tournaments.{Tournament, TournamentRegistration, TournamentMatch}
  alias Tabletop.Accounts.Scope

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Tournaments.subscribe_tournament(id)

    {:ok, load(socket, id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "standings"
    round_tab = params["round"]
    {:noreply, socket |> assign(:tab, tab) |> assign(:round_tab, round_tab)}
  end

  @impl true
  def handle_info({:tournament_updated, id}, socket) do
    {:noreply, load(socket, id)}
  end

  defp load(socket, id) do
    t = Tournaments.get_tournament!(id)
    user_id = user_id(socket.assigns.current_scope)
    registrations = Tournaments.list_registrations(id)
    my_reg = user_id && Enum.find(registrations, &(&1.user_id == user_id))
    my_match = user_id && Tournaments.current_match_for_user(id, user_id)

    standings =
      if t.status in [:swiss, :cut, :finished] do
        Tournaments.standings(id)
      else
        []
      end

    rounds = Tournaments.list_rounds(id)

    matches_by_round =
      Map.new(rounds, fn r -> {r.id, Tournaments.list_matches_for_round(r.id)} end)

    socket
    |> assign(:tournament, t)
    |> assign(:page_title, t.name)
    |> assign(:registrations, registrations)
    |> assign(:my_registration, my_reg)
    |> assign(:my_match, my_match)
    |> assign(:standings, standings)
    |> assign(:rounds, rounds)
    |> assign(:matches_by_round, matches_by_round)
    |> assign(:registration_form, registration_form(t))
  end

  defp registration_form(%Tournament{} = t) do
    to_form(Tournaments.change_registration(%TournamentRegistration{tournament_id: t.id}))
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_), do: nil

  @impl true
  def handle_event("validate-registration", %{"tournament_registration" => params}, socket) do
    changeset =
      %TournamentRegistration{tournament_id: socket.assigns.tournament.id}
      |> Tournaments.change_registration(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :registration_form, to_form(changeset))}
  end

  def handle_event("register", %{"tournament_registration" => params}, socket) do
    case Tournaments.register(socket.assigns.current_scope, socket.assigns.tournament.id, params) do
      {:ok, _reg} ->
        {:noreply,
         socket
         |> put_flash(:info, "Registered!")
         |> load(socket.assigns.tournament.id)}

      {:error, :registration_closed} ->
        {:noreply, put_flash(socket, :error, "Registration is closed.")}

      {:error, :tournament_full} ->
        {:noreply, put_flash(socket, :error, "Tournament is full.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :registration_form, to_form(changeset))}
    end
  end

  def handle_event("drop", _params, socket) do
    case Tournaments.drop(socket.assigns.current_scope, socket.assigns.tournament.id) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "You've dropped from the tournament.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't drop.")}
    end
  end

  def handle_event("check_in", _params, socket) do
    case Tournaments.check_in(socket.assigns.current_scope, socket.assigns.tournament.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "You're checked in!")
         |> load(socket.assigns.tournament.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't check in.")}
    end
  end

  def handle_event("report", %{"match_id" => match_id, "result" => result}, socket) do
    case Tournaments.report_result(socket.assigns.current_scope, match_id, result) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Result reported.")
         |> load(socket.assigns.tournament.id)}

      {:error, :already_confirmed} ->
        {:noreply, put_flash(socket, :error, "Match already confirmed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't report result.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@tournament.name}
        <:subtitle>
          {Tournament.format_name(@tournament)} · {status_label(@tournament.status)}
        </:subtitle>
        <:actions :if={Scope.admin?(@current_scope)}>
          <.button navigate={~p"/tournaments/#{@tournament}/admin"}>Admin</.button>
        </:actions>
      </.header>

      <p
        :if={@tournament.starts_at && @tournament.status not in [:finished, :cancelled]}
        class="mb-4 text-sm"
      >
        <span class="opacity-70">Starts</span>
        <.local_datetime
          id="tournament-starts-at"
          at={@tournament.starts_at}
          countdown={@tournament.status in [:draft, :registration]}
        />
      </p>

      <p :if={@tournament.description} class="mb-4">{@tournament.description}</p>

      <.my_match
        :if={@my_match}
        match={@my_match}
        current_user_id={user_id(@current_scope)}
      />

      <.check_in_panel
        :if={
          (@tournament.status == :check_in and @my_registration) &&
            is_nil(@my_registration.dropped_at)
        }
        registration={@my_registration}
      />

      <p
        :if={(@tournament.status == :check_in and @current_scope) && !@my_registration}
        class="card bg-base-200 p-4 my-4 text-sm opacity-70"
      >
        Registration is closed — the organiser has opened check-in.
      </p>

      <.register_panel
        :if={(@tournament.status == :registration and @current_scope) && !@my_registration}
        form={@registration_form}
      />

      <div :if={@my_registration && @tournament.status in [:swiss, :cut]} class="my-4">
        <.button phx-click="drop" data-confirm="Drop from this tournament?">Drop</.button>
      </div>

      <.tabs tournament={@tournament} tab={@tab} />

      <section :if={@tab == "standings"} class="my-4">
        <.standings_table :if={@standings != []} rows={@standings} />
        <p :if={@standings == []} class="opacity-60">
          Standings will appear once the tournament starts.
        </p>
      </section>

      <section :if={@tab == "players"} class="my-4">
        <.players_list
          registrations={@registrations}
          tournament={@tournament}
          current_scope={@current_scope}
        />
      </section>

      <section :if={@tab == "matches"} class="my-4">
        <.matches_panel
          tournament={@tournament}
          rounds={@rounds}
          matches_by_round={@matches_by_round}
          round_tab={@round_tab}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :tournament, :any, required: true
  attr :tab, :string, required: true

  defp tabs(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-bordered">
      <.link
        patch={~p"/tournaments/#{@tournament}?tab=standings"}
        role="tab"
        class={["tab", @tab == "standings" && "tab-active"]}
      >
        Standings
      </.link>
      <.link
        patch={~p"/tournaments/#{@tournament}?tab=players"}
        role="tab"
        class={["tab", @tab == "players" && "tab-active"]}
      >
        Players
      </.link>
      <.link
        patch={~p"/tournaments/#{@tournament}?tab=matches"}
        role="tab"
        class={["tab", @tab == "matches" && "tab-active"]}
      >
        Matches
      </.link>
    </div>
    """
  end

  attr :tournament, :any, required: true
  attr :rounds, :list, required: true
  attr :matches_by_round, :map, required: true
  attr :round_tab, :any, required: true

  defp matches_panel(assigns) do
    active = assigns.round_tab || default_round_id(assigns.rounds)
    assigns = assign(assigns, :active_round_id, active)

    ~H"""
    <div :if={@rounds == []} class="opacity-60">No rounds have been played yet.</div>

    <div :if={@rounds != []}>
      <div role="tablist" class="tabs tabs-boxed mb-4">
        <.link
          :for={r <- @rounds}
          patch={~p"/tournaments/#{@tournament}?tab=matches&round=#{r.id}"}
          role="tab"
          class={["tab", @active_round_id == r.id && "tab-active"]}
        >
          {round_label(r)}
        </.link>
      </div>

      <.round_matches_table
        :for={r <- @rounds}
        :if={@active_round_id == r.id}
        round={r}
        matches={Map.get(@matches_by_round, r.id, [])}
      />
    </div>
    """
  end

  defp default_round_id([]), do: nil
  defp default_round_id(rounds), do: List.last(rounds).id

  defp round_label(%{kind: :swiss, round_number: n}), do: "Swiss #{n}"

  defp round_label(%{kind: :top_cut, cut_stage: stage, round_number: n}) do
    "Top cut " <> (cut_stage_label(stage) || "round #{n}")
  end

  defp cut_stage_label(1), do: "QF"
  defp cut_stage_label(2), do: "SF"
  defp cut_stage_label(3), do: "Final"
  defp cut_stage_label(_), do: nil

  attr :round, :any, required: true
  attr :matches, :list, required: true

  defp round_matches_table(assigns) do
    ~H"""
    <table class="table w-full">
      <thead>
        <tr>
          <th>Table</th>
          <th>Player 1</th>
          <th>Player 2</th>
          <th>Result</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={m <- @matches}>
          <td>{m.table_number}</td>
          <td>{m.player1 && m.player1.name}</td>
          <td>{(m.player2 && m.player2.name) || "(bye)"}</td>
          <td>{TournamentMatch.result_description(m.confirmed_result)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :match, :map, required: true
  attr :current_user_id, :any, required: true

  defp my_match(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 my-4">
      <h2 class="font-semibold text-lg mb-2">Your current match</h2>
      <div :if={@match.player2_id == nil}>
        You have a bye this round.
      </div>
      <div :if={@match.player2_id != nil}>
        <div>
          Table {@match.table_number}: <strong>{@match.player1.name}</strong>
          vs <strong>{@match.player2.name}</strong>
        </div>
        <div :if={@match.game_id} class="my-2">
          <.button variant="primary" navigate={~p"/games/#{@match.game_id}"}>
            Open live game
          </.button>
        </div>

        <div
          id={"round-deadline-" <> @match.round.id}
          class="text-sm opacity-70 my-2"
          phx-hook=".RoundDeadline"
          data-deadline={@match.round.deadline_at && DateTime.to_iso8601(@match.round.deadline_at)}
        >
          Round deadline: <span data-countdown>calculating…</span>
        </div>
        <div :if={@match.confirmed_result}>
          <em>Result confirmed: {TournamentMatch.result_description(@match.confirmed_result)}</em>
        </div>
        <div :if={is_nil(@match.confirmed_result)} class="flex gap-2 flex-wrap">
          <div :if={reported_by(@match, @current_user_id)}>
            You reported: <strong>{reported_by(@match, @current_user_id)}</strong>
          </div>
          <.button
            :if={!reported_by(@match, @current_user_id)}
            phx-click="report"
            phx-value-match_id={@match.id}
            phx-value-result={my_side(@match, @current_user_id, :win)}
          >
            I won
          </.button>
          <.button
            :if={!reported_by(@match, @current_user_id)}
            phx-click="report"
            phx-value-match_id={@match.id}
            phx-value-result={my_side(@match, @current_user_id, :loss)}
          >
            I lost
          </.button>
          <.button
            :if={!reported_by(@match, @current_user_id)}
            phx-click="report"
            phx-value-match_id={@match.id}
            phx-value-result="draw"
          >
            Draw
          </.button>
        </div>
        <div :if={reports_disagree?(@match)} class="mt-2 text-warning">
          Reports disagree. Awaiting admin adjudication.
        </div>
      </div>
    </section>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RoundDeadline">
      export default {
        mounted() { this.tick(); this.t = setInterval(() => this.tick(), 1000); },
        destroyed() { clearInterval(this.t); },
        tick() {
          const dl = this.el.dataset.deadline;
          const span = this.el.querySelector("[data-countdown]");
          if (!dl || !span) return;
          const ms = new Date(dl).getTime() - Date.now();
          if (ms <= 0) { span.textContent = "time's up"; return; }
          const s = Math.floor(ms / 1000);
          const m = Math.floor(s / 60);
          span.textContent = `${m}m ${s % 60}s`;
        }
      }
    </script>
    """
  end

  defp my_side(%{player1_id: id}, id, :win), do: "p1_win"
  defp my_side(%{player1_id: id}, id, :loss), do: "p2_win"
  defp my_side(%{player2_id: id}, id, :win), do: "p2_win"
  defp my_side(%{player2_id: id}, id, :loss), do: "p1_win"

  defp reported_by(%{player1_id: id, player1_reported: r}, id), do: r
  defp reported_by(%{player2_id: id, player2_reported: r}, id), do: r
  defp reported_by(_, _), do: nil

  defp reports_disagree?(%{player1_reported: r1, player2_reported: r2})
       when is_binary(r1) and is_binary(r2),
       do: r1 != r2

  defp reports_disagree?(_), do: false

  attr :registration, :any, required: true

  defp check_in_panel(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 my-4">
      <h2 class="font-semibold text-lg mb-2">Check-in</h2>
      <div :if={@registration.checked_in_at} class="text-success flex items-center gap-2">
        <.icon name="hero-check-circle" class="size-5" /> You're checked in. Hang tight for the start.
      </div>
      <div :if={is_nil(@registration.checked_in_at)} class="space-y-3">
        <p class="text-sm">
          Check in to confirm you're playing. Players who don't check in before the organiser
          starts the tournament are dropped.
        </p>
        <.button variant="primary" phx-click="check_in">Check in</.button>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true

  defp register_panel(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 my-4">
      <h2 class="font-semibold text-lg mb-2">Sign up</h2>
      <.form for={@form} phx-change="validate-registration" phx-submit="register">
        <.input field={@form[:hero]} type="text" label="Hero" />
        <.input
          field={@form[:decklist_url]}
          type="text"
          label="Fabrary decklist URL"
          placeholder="https://fabrary.net/decks/..."
        />
        <.button variant="primary" phx-disable-with="Registering...">Register</.button>
      </.form>
    </section>
    """
  end

  attr :rows, :list, required: true

  defp standings_table(assigns) do
    ~H"""
    <section class="my-6">
      <h2 class="font-semibold text-lg mb-2">Standings</h2>
      <table class="table w-full">
        <thead>
          <tr>
            <th>#</th>
            <th>Player</th>
            <th>Points</th>
            <th>OMW%</th>
            <th>GW%</th>
            <th>OGW%</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td>{row.rank}</td>
            <td>{row.user && row.user.name}</td>
            <td>{row.match_points}</td>
            <td>{pct(row.omw)}</td>
            <td>{pct(row.gw)}</td>
            <td>{pct(row.ogw)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp pct(f), do: :erlang.float_to_binary(f * 100.0, decimals: 1) <> "%"

  attr :registrations, :list, required: true
  attr :tournament, :any, required: true
  attr :current_scope, :any, required: true

  defp players_list(assigns) do
    ~H"""
    <section class="my-6">
      <h2 class="font-semibold text-lg mb-2">
        Registered players ({length(@registrations)})
      </h2>
      <ul class="divide-y divide-base-300">
        <li :for={r <- @registrations} class="py-2 flex justify-between">
          <div>
            <strong>{r.user && r.user.name}</strong>
            <span :if={r.hero} class="opacity-70 ml-2">{r.hero}</span>
            <span :if={r.dropped_at} class="badge badge-ghost ml-2">dropped</span>
          </div>
          <div :if={can_view_decklist?(r, @current_scope, @tournament)}>
            <a class="link" href={r.decklist_url} target="_blank" rel="noopener">deck</a>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp can_view_decklist?(_reg, _scope, %{status: :finished}), do: true

  defp can_view_decklist?(reg, %Scope{user: %{id: user_id}}, _t) when reg.user_id == user_id,
    do: true

  defp can_view_decklist?(_reg, scope, _t), do: Scope.admin?(scope)

  defp status_label(:draft), do: "Draft"
  defp status_label(:registration), do: "Registration open"
  defp status_label(:check_in), do: "Check-in"
  defp status_label(:swiss), do: "Swiss"
  defp status_label(:cut), do: "Top cut"
  defp status_label(:finished), do: "Finished"
  defp status_label(:cancelled), do: "Cancelled"
end
