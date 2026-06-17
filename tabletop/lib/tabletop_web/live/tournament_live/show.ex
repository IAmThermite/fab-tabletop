defmodule TabletopWeb.TournamentLive.Show do
  use TabletopWeb, :live_view

  alias Tabletop.Tournaments
  alias Tabletop.Tournaments.{Tournament, TournamentRegistration, TournamentMatch}
  alias Tabletop.Accounts.Scope
  alias Tabletop.Heroes

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

    # Only surface the player's current match while the tournament is actually
    # in progress — once it's finished (or cancelled) there's no "current match".
    my_match =
      if user_id && t.status in [:swiss, :cut] do
        Tournaments.current_match_for_user(id, user_id)
      end

    standings =
      if t.status in [:swiss, :cut, :finished] do
        Tournaments.standings(id)
      else
        []
      end

    rounds = Tournaments.list_rounds(id)

    matches_by_round =
      Map.new(rounds, fn r -> {r.id, Tournaments.list_matches_for_round(r.id)} end)

    # Lookups for display: a player's chosen hero (for portraits) and seed
    # (for bracket ordering), keyed by user_id.
    hero_by_user = Map.new(registrations, &{&1.user_id, &1.hero})
    seed_by_user = Map.new(registrations, &{&1.user_id, &1.seed})

    socket
    |> assign(:tournament, t)
    |> assign(:page_title, t.name)
    |> assign(:current_user_id, user_id)
    |> assign(:registrations, registrations)
    |> assign(:my_registration, my_reg)
    |> assign(:my_match, my_match)
    |> assign(:standings, standings)
    |> assign(:rounds, rounds)
    |> assign(:matches_by_round, matches_by_round)
    |> assign(:hero_by_user, hero_by_user)
    |> assign(:seed_by_user, seed_by_user)
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
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-4xl">
      <.header>
        {@tournament.name}
        <:subtitle>
          {Tournament.format_name(@tournament)}
          <.tournament_status_badge status={@tournament.status} class="ml-1 align-middle" />
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

      <div
        :if={@tournament.status == :finished and @tournament.winner}
        class="my-4 flex items-center gap-3 rounded-box border border-success/30 bg-success/10 p-4"
      >
        <.icon name="hero-trophy" class="size-8 shrink-0 text-success" />
        <div class="min-w-0">
          <div class="font-display text-sm font-bold uppercase tracking-wide text-success">
            Champion
          </div>
          <.player_identity
            user={@tournament.winner}
            hero={Map.get(@hero_by_user, @tournament.winner_id)}
            portrait_class="size-10"
          />
        </div>
      </div>

      <.my_match
        :if={@my_match}
        match={@my_match}
        current_user_id={@current_user_id}
        hero_by_user={@hero_by_user}
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
        tournament={@tournament}
      />

      <div :if={@my_registration && @tournament.status in [:swiss, :cut]} class="my-4">
        <.button phx-click="drop" data-confirm="Drop from this tournament?">Drop</.button>
      </div>

      <.tabs tournament={@tournament} tab={@tab} />

      <section :if={@tab == "standings"} class="my-4">
        <.standings_table
          :if={@standings != []}
          rows={@standings}
          current_user_id={@current_user_id}
        />
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
          hero_by_user={@hero_by_user}
          seed_by_user={@seed_by_user}
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
  attr :hero_by_user, :map, required: true
  attr :seed_by_user, :map, required: true

  defp matches_panel(assigns) do
    active_id = assigns.round_tab || default_round_id(assigns.rounds)
    active_round = Enum.find(assigns.rounds, &(&1.id == active_id))

    assigns =
      assigns
      |> assign(:active_round_id, active_id)
      |> assign(:active_round, active_round)

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

      <%!-- Top cut renders as a full bracket; swiss rounds as a table. --%>
      <.bracket
        :if={@active_round && @active_round.kind == :top_cut}
        rounds={Enum.filter(@rounds, &(&1.kind == :top_cut))}
        matches_by_round={@matches_by_round}
        seed_by_user={@seed_by_user}
        hero_by_user={@hero_by_user}
      />

      <.round_matches_table
        :if={@active_round && @active_round.kind != :top_cut}
        matches={Map.get(@matches_by_round, @active_round_id, [])}
        hero_by_user={@hero_by_user}
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

  attr :matches, :list, required: true
  attr :hero_by_user, :map, required: true

  defp round_matches_table(assigns) do
    ~H"""
    <table class="table table-zebra w-full">
      <thead>
        <tr>
          <th class="w-12">#</th>
          <th>Player 1</th>
          <th>Player 2</th>
          <th class="text-right">Result</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={m <- @matches}>
          <td class="text-base-content/60">{m.table_number}</td>
          <td>
            <div class="flex items-center gap-2">
              <.hero_portrait hero={Map.get(@hero_by_user, m.player1_id)} class="size-7" />
              <span class="truncate">{m.player1 && m.player1.name}</span>
            </div>
          </td>
          <td>
            <div class="flex items-center gap-2">
              <.hero_portrait
                :if={m.player2_id}
                hero={Map.get(@hero_by_user, m.player2_id)}
                class="size-7"
              />
              <span class={["truncate", is_nil(m.player2_id) && "opacity-60 italic"]}>
                {(m.player2 && m.player2.name) || "bye"}
              </span>
            </div>
          </td>
          <td class="text-right">
            <.match_result
              :if={m.confirmed_result}
              match={m}
              result={m.confirmed_result}
              hero_by_user={@hero_by_user}
              class="text-sm"
            />
            <span :if={is_nil(m.confirmed_result)} class="text-xs text-base-content/50">pending</span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :match, :map, required: true
  attr :current_user_id, :any, required: true
  attr :hero_by_user, :map, required: true

  defp my_match(assigns) do
    ~H"""
    <section class="card border-2 border-primary bg-base-100 p-4 my-4">
      <h2 class="font-display text-lg font-bold mb-3">Your current match</h2>

      <div :if={@match.player2_id == nil} class="flex items-center gap-2 text-base-content/80">
        <.icon name="hero-trophy" class="size-5 text-success" />
        You have a bye this round — an automatic win.
      </div>

      <div :if={@match.player2_id != nil} class="space-y-3">
        <div class="flex items-center justify-center gap-4">
          <div class="flex flex-1 flex-col items-center gap-1 min-w-0">
            <.hero_portrait hero={Map.get(@hero_by_user, @match.player1_id)} class="size-12" />
            <span class="text-sm font-medium truncate max-w-full">{@match.player1.name}</span>
          </div>
          <span class="text-xs font-bold text-base-content/40">VS</span>
          <div class="flex flex-1 flex-col items-center gap-1 min-w-0">
            <.hero_portrait hero={Map.get(@hero_by_user, @match.player2_id)} class="size-12" />
            <span class="text-sm font-medium truncate max-w-full">{@match.player2.name}</span>
          </div>
        </div>
        <div class="text-center text-sm text-base-content/60">Table {@match.table_number}</div>

        <.button
          :if={@match.game_id && !TournamentMatch.result_entered?(@match)}
          variant="primary"
          navigate={~p"/games/#{@match.game_id}"}
        >
          <.icon name="hero-video-camera" class="size-4" /> Open live game
        </.button>
        <p :if={TournamentMatch.result_entered?(@match)} class="text-sm text-base-content/60">
          The game has ended — a result has been entered.
        </p>

        <.round_timer round={@match.round} />

        <div :if={@match.confirmed_result} class="text-success">
          <div class="flex items-center gap-2 font-medium">
            <.icon name="hero-check-circle" class="size-5" /> Result confirmed
          </div>
          <.match_result
            match={@match}
            result={@match.confirmed_result}
            hero_by_user={@hero_by_user}
            class="ml-7"
          />
        </div>

        <div :if={is_nil(@match.confirmed_result)}>
          <div :if={reported_by(@match, @current_user_id)} class="text-sm text-base-content/70">
            You reported:
            <strong>{match_result_text(@match, reported_by(@match, @current_user_id))}</strong>
            <span class="opacity-70">— waiting on confirmation.</span>
          </div>
          <div :if={!reported_by(@match, @current_user_id)} class="space-y-1">
            <p class="text-sm text-base-content/70">Report your result:</p>
            <div class="flex gap-2 flex-wrap">
              <.button
                variant="primary"
                phx-click="report"
                phx-value-match_id={@match.id}
                phx-value-result={my_side(@match, @current_user_id, :win)}
              >
                I won
              </.button>
              <.button
                variant="danger"
                phx-click="report"
                phx-value-match_id={@match.id}
                phx-value-result={my_side(@match, @current_user_id, :loss)}
              >
                I lost
              </.button>
              <.button
                phx-click="report"
                phx-value-match_id={@match.id}
                phx-value-result="draw"
              >
                Draw
              </.button>
            </div>
          </div>
          <div :if={reports_disagree?(@match)} class="mt-2 flex items-center gap-2 text-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            Reports disagree — awaiting admin adjudication.
          </div>
        </div>
      </div>
    </section>
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
  attr :tournament, :any, required: true

  defp register_panel(assigns) do
    ~H"""
    <section class="card bg-base-200 p-4 my-4">
      <h2 class="font-semibold text-lg mb-2">Sign up</h2>
      <.form for={@form} phx-change="validate-registration" phx-submit="register">
        <.input
          field={@form[:hero]}
          type="select"
          label="Hero"
          prompt="— Select hero —"
          options={Heroes.options_for(@tournament.format)}
        />
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
  attr :current_user_id, :any, default: nil

  defp standings_table(assigns) do
    ~H"""
    <section class="my-6">
      <h2 class="font-display text-lg font-bold mb-2">Standings</h2>
      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-zebra w-full">
          <thead>
            <tr>
              <th class="w-10">#</th>
              <th>Player</th>
              <th class="text-center">Pts</th>
              <th class="text-center">W/D/L</th>
              <th class="text-center">
                <.stat_header
                  label="OMW%"
                  tip="Opponents' Match-Win % — strength of schedule: the average match-win rate of everyone you've played, floored at 33%."
                />
              </th>
              <th class="text-center">
                <.stat_header
                  label="GW%"
                  tip="Game-Win % — your share of individual games won across all matches."
                />
              </th>
              <th class="text-center">
                <.stat_header
                  label="OGW%"
                  tip="Opponents' Game-Win % — the average game-win rate of everyone you've played, floored at 33%."
                />
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              class={row.id == @current_user_id && "bg-primary/10 font-semibold"}
            >
              <td class="tabular-nums text-base-content/60">{row.rank}</td>
              <td>
                <div class="flex items-center gap-2">
                  <.hero_portrait hero={row.registration && row.registration.hero} class="size-7" />
                  <div class="min-w-0 leading-tight">
                    <div class="truncate">{row.user && row.user.name}</div>
                    <div
                      :if={row.registration && hero_name(row.registration.hero)}
                      class="text-xs font-normal text-base-content/60 truncate"
                    >
                      {hero_name(row.registration.hero)}
                    </div>
                  </div>
                </div>
              </td>
              <td class="text-center font-bold tabular-nums">{row.match_points}</td>
              <td class="text-center tabular-nums">{row.wins}/{row.draws}/{row.losses}</td>
              <td class="text-center tabular-nums">{pct(row.omw)}</td>
              <td class="text-center tabular-nums">{pct(row.gw)}</td>
              <td class="text-center tabular-nums">{pct(row.ogw)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp pct(f), do: :erlang.float_to_binary(f * 100.0, decimals: 1) <> "%"

  attr :label, :string, required: true
  attr :tip, :string, required: true

  defp stat_header(assigns) do
    # Native `title` rather than the daisyUI `tooltip` class: the tooltip's
    # absolutely-positioned `:before` bubble (long tip text) inflates the
    # standings table's horizontal scroll width, leaving a phantom blank
    # scroll region. `title` has zero layout impact.
    ~H"""
    <span class="cursor-help underline decoration-dotted underline-offset-2" title={@tip}>
      {@label}
    </span>
    """
  end

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
        <li :for={r <- @registrations} class="py-2 flex items-center justify-between gap-3">
          <div class="flex items-center gap-2 min-w-0">
            <.hero_portrait hero={r.hero} class="size-8" />
            <div class="min-w-0">
              <strong class="truncate">{r.user && r.user.name}</strong>
              <span :if={hero_name(r.hero)} class="opacity-70 ml-1 text-sm">{hero_name(r.hero)}</span>
              <span :if={r.dropped_at} class="badge badge-ghost badge-sm ml-2">dropped</span>
            </div>
          </div>
          <div :if={can_view_decklist?(r, @current_scope, @tournament)} class="shrink-0">
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
end
