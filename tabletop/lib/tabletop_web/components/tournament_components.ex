defmodule TabletopWeb.TournamentComponents do
  @moduledoc """
  Shared UI components for the tournament screens (Index, Show, Admin).

  Centralises the status badge styling (previously duplicated across the three
  LiveViews) and hero display (portrait + name), reusing `Tabletop.Heroes`.
  """
  use Phoenix.Component

  import TabletopWeb.CoreComponents, only: [icon: 1]

  alias Tabletop.Heroes

  # Single source of truth: status -> {label, badge class}.
  @status_meta %{
    draft: {"Draft", "badge-ghost"},
    registration: {"Registration open", "badge-primary"},
    check_in: {"Check-in", "badge-accent"},
    swiss: {"Swiss", "badge-info"},
    cut: {"Top cut", "badge-warning"},
    finished: {"Finished", "badge-success"},
    cancelled: {"Cancelled", "badge-error"}
  }

  @doc "Human-readable label for a tournament status."
  def tournament_status_label(status) do
    @status_meta |> Map.get(status, {humanize_status(status), "badge-ghost"}) |> elem(0)
  end

  defp humanize_status(status), do: status |> to_string() |> String.capitalize()

  attr :status, :atom, required: true
  attr :class, :string, default: nil

  @doc "Coloured pill for a tournament status."
  def tournament_status_badge(assigns) do
    {label, badge_class} =
      Map.get(@status_meta, assigns.status, {humanize_status(assigns.status), "badge-ghost"})

    assigns = assign(assigns, label: label, badge_class: badge_class)

    ~H"""
    <span class={["badge", @badge_class, @class]}>{@label}</span>
    """
  end

  attr :hero, :string, default: nil, doc: "hero slug (or legacy free text)"
  attr :class, :string, default: "size-8", doc: "size utility for the avatar"

  @doc """
  Round hero portrait. Renders the hero art when the slug is known, otherwise a
  neutral placeholder — so legacy free-text hero values degrade gracefully.
  """
  def hero_portrait(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full bg-base-200 ring-1 ring-base-300",
      @class
    ]}>
      <img
        :if={@hero && Heroes.known?(@hero)}
        src={Heroes.icon_path(@hero)}
        alt={Heroes.name(@hero)}
        class="size-full object-cover"
      />
      <.icon
        :if={!(@hero && Heroes.known?(@hero))}
        name="hero-user"
        class="size-4 text-base-content/40"
      />
    </span>
    """
  end

  @doc "Display name for a registration hero (slug -> name; legacy free text passes through)."
  def hero_name(nil), do: nil
  def hero_name(""), do: nil
  def hero_name(hero), do: Heroes.name(hero) || hero

  attr :user, :any, default: nil, doc: "%User{} (or nil); supplies the name"
  attr :name, :string, default: nil, doc: "explicit name override (else user.name)"
  attr :hero, :string, default: nil, doc: "hero slug for the portrait + subtext"
  attr :portrait_class, :string, default: "size-8"
  attr :class, :string, default: nil

  @doc """
  A player's identity rendered like a standings row: hero portrait, name, and
  hero name as subtext. Used wherever a single player needs to read the same as
  the standings (e.g. the finished-tournament champion).
  """
  def player_identity(assigns) do
    assigns =
      assign_new(assigns, :resolved_name, fn ->
        assigns.name || (assigns.user && assigns.user.name) || "Unknown player"
      end)

    ~H"""
    <div class={["flex items-center gap-2 min-w-0", @class]}>
      <.hero_portrait hero={@hero} class={@portrait_class} />
      <div class="min-w-0 leading-tight">
        <div class="truncate font-medium">{@resolved_name}</div>
        <div :if={hero_name(@hero)} class="text-xs font-normal text-base-content/60 truncate">
          {hero_name(@hero)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Plain-text match result using player names rather than "p1/p2 win"
  (e.g. "Alice won"). Needs the match's `player1`/`player2` preloaded.
  """
  def match_result_text(_match, "draw"), do: "Draw"
  def match_result_text(_match, "double_loss"), do: "Double loss"
  def match_result_text(_match, "bye"), do: "Bye"
  def match_result_text(_match, nil), do: "Pending"
  def match_result_text(match, "p1_win"), do: "#{result_player_name(match.player1)} won"
  def match_result_text(match, "p2_win"), do: "#{result_player_name(match.player2)} won"
  def match_result_text(_match, other), do: other

  defp result_player_name(%{name: name}) when is_binary(name), do: name
  defp result_player_name(_), do: "Unknown player"

  attr :match, :any, required: true
  attr :result, :any, required: true
  attr :hero_by_user, :map, default: %{}
  attr :class, :string, default: nil

  @doc """
  Match result as the winning player's name, with their hero as subtext
  (draws / double-losses / byes show just the label, no hero).
  """
  def match_result(assigns) do
    winner_id =
      case assigns.result do
        "p1_win" -> assigns.match.player1_id
        "p2_win" -> assigns.match.player2_id
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:label, match_result_text(assigns.match, assigns.result))
      |> assign(:winner_hero, winner_id && Map.get(assigns.hero_by_user, winner_id))

    ~H"""
    <div class={@class}>
      <div class="leading-tight">{@label}</div>
      <div :if={hero_name(@winner_hero)} class="text-xs text-base-content/60 leading-tight">
        {hero_name(@winner_hero)}
      </div>
    </div>
    """
  end

  attr :tournament, :any, required: true
  attr :class, :string, default: nil

  @doc """
  Lifecycle stepper for the admin page: Draft → Registration → Check-in →
  Swiss → (Top cut) → Finished, with steps up to the current status filled in.
  The Top cut step is omitted when the tournament has no cut. A cancelled
  tournament shows a single error state instead.
  """
  def phase_stepper(assigns) do
    steps = phase_steps(assigns.tournament)

    assigns =
      assigns
      |> assign(:steps, steps)
      |> assign(:current, phase_index(assigns.tournament.status, steps))
      |> assign(:detail, phase_detail(assigns.tournament))

    ~H"""
    <div class={@class}>
      <div :if={@tournament.status == :cancelled} class="alert alert-error">
        <.icon name="hero-x-circle" class="size-5" /> This tournament was cancelled.
      </div>
      <ul :if={@tournament.status != :cancelled} class="steps w-full">
        <li
          :for={{step, idx} <- Enum.with_index(@steps)}
          class={["step", idx <= @current && "step-primary"]}
        >
          <span class="flex flex-col leading-tight">
            {step.label}
            <span :if={idx == @current and @detail} class="text-xs font-normal text-base-content/60">
              {@detail}
            </span>
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp phase_steps(tournament) do
    cut =
      if (tournament.top_cut_size || 0) > 0,
        do: [%{key: :cut, label: "Top cut"}],
        else: []

    [
      %{key: :draft, label: "Draft"},
      %{key: :registration, label: "Registration"},
      %{key: :check_in, label: "Check-in"},
      %{key: :swiss, label: "Swiss"}
    ] ++ cut ++ [%{key: :finished, label: "Finished"}]
  end

  defp phase_index(status, steps) do
    Enum.find_index(steps, &(&1.key == status)) || -1
  end

  # Sub-label under the active step: which Swiss or top-cut round is currently
  # running. Nil outside the in-progress phases (or when the current round isn't
  # loaded). Expects `current_round` to be preloaded.
  defp phase_detail(%{status: :swiss} = tournament) do
    case tournament.current_round do
      %{round_number: n} -> "Round #{n} of #{tournament.swiss_rounds}"
      _ -> nil
    end
  end

  defp phase_detail(%{status: :cut} = tournament) do
    case tournament.current_round do
      %{cut_stage: stage} when is_integer(stage) -> "Round #{stage}"
      _ -> nil
    end
  end

  defp phase_detail(_), do: nil

  @doc """
  Short label for where an in-progress tournament is up to, e.g. "Swiss 3/5" or
  "Top cut". Expects `current_round` to be loaded; falls back gracefully.
  """
  def round_progress_label(%{status: :swiss} = tournament) do
    case tournament.current_round do
      %{round_number: n} -> "Swiss #{n}/#{tournament.swiss_rounds}"
      _ -> "Swiss"
    end
  end

  def round_progress_label(%{status: :cut}), do: "Top cut"
  def round_progress_label(_), do: nil

  attr :round, :any, required: true
  attr :class, :string, default: nil

  @doc """
  Live round countdown + progress bar for a round, driven entirely by the
  round's `deadline_at` (the single source of truth) and `started_at` (for the
  bar fill). Shared by the player Show page and the admin page so they always
  agree.

  The element's `id` is keyed by the deadline and it's marked
  `phx-update="ignore"`, which means:

    * unrelated LiveView re-renders (e.g. switching tabs) never touch the
      JS-managed countdown/bar, so it no longer "recalculates" or flickers; and
    * when an admin extends the round (`extend_round` updates `deadline_at` and
      broadcasts), the id changes, the element remounts, and every viewer's
      timer picks up the new deadline.
  """
  def round_timer(assigns) do
    ~H"""
    <div
      :if={@round && @round.deadline_at}
      id={"round-timer-#{@round.id}-#{DateTime.to_unix(@round.deadline_at)}"}
      phx-hook=".RoundTimer"
      phx-update="ignore"
      data-deadline={DateTime.to_iso8601(@round.deadline_at)}
      data-start={@round.started_at && DateTime.to_iso8601(@round.started_at)}
      class={@class}
    >
      <div class="mb-1 flex items-center justify-between text-xs text-base-content/70">
        <span>Round time</span>
        <span data-countdown>calculating…</span>
      </div>
      <progress data-bar class="progress progress-primary w-full" value="0" max="100"></progress>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RoundTimer">
      export default {
        mounted() { this.tick(); this.t = setInterval(() => this.tick(), 1000); },
        destroyed() { clearInterval(this.t); },
        tick() {
          const end = new Date(this.el.dataset.deadline).getTime();
          const start = this.el.dataset.start ? new Date(this.el.dataset.start).getTime() : null;
          const now = Date.now();
          const ms = end - now;
          const span = this.el.querySelector("[data-countdown]");
          const bar = this.el.querySelector("[data-bar]");
          if (span) {
            if (ms <= 0) { span.textContent = "time's up"; }
            else { const s = Math.floor(ms / 1000); span.textContent = `${Math.floor(s / 60)}m ${s % 60}s`; }
          }
          if (bar && start) {
            const total = end - start;
            const pct = total > 0 ? Math.min(100, Math.max(0, ((now - start) / total) * 100)) : 100;
            bar.value = pct;
            bar.classList.toggle("progress-error", ms <= 0);
            bar.classList.toggle("progress-primary", ms > 0);
          }
        }
      }
    </script>
    """
  end

  attr :rounds, :list, required: true, doc: "top-cut rounds, in stage order"
  attr :matches_by_round, :map, required: true
  attr :seed_by_user, :map, default: %{}
  attr :hero_by_user, :map, default: %{}

  @doc """
  Single-elimination bracket: one column per stage (Quarterfinals → Final),
  each match a small card with seeds, portraits, and the winner highlighted.
  """
  def bracket(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <div class="flex min-w-max items-stretch gap-6 py-2">
        <div :for={r <- @rounds} class="flex min-w-56 flex-col justify-around gap-4">
          <div class="text-center text-xs font-semibold uppercase tracking-wide text-base-content/60">
            {bracket_round_label(Map.get(@matches_by_round, r.id, []))}
          </div>
          <.bracket_match
            :for={m <- Map.get(@matches_by_round, r.id, [])}
            match={m}
            seed_by_user={@seed_by_user}
            hero_by_user={@hero_by_user}
          />
        </div>
      </div>
    </div>
    """
  end

  defp bracket_round_label(matches) do
    case length(matches) do
      1 -> "Final"
      2 -> "Semifinals"
      4 -> "Quarterfinals"
      n -> "Round of #{n * 2}"
    end
  end

  attr :match, :any, required: true
  attr :seed_by_user, :map, default: %{}
  attr :hero_by_user, :map, default: %{}

  defp bracket_match(assigns) do
    assigns = assign(assigns, :winner, bracket_winner(assigns.match))

    ~H"""
    <div class="overflow-hidden rounded-lg border border-base-300 bg-base-100 text-sm shadow-sm">
      <.bracket_player
        player={@match.player1}
        games={@match.player1_games_won}
        winner={@winner == :p1}
        seed_by_user={@seed_by_user}
        hero_by_user={@hero_by_user}
      />
      <div class="border-t border-base-300"></div>
      <.bracket_player
        player={@match.player2}
        games={@match.player2_games_won}
        winner={@winner == :p2}
        bye={is_nil(@match.player2_id)}
        seed_by_user={@seed_by_user}
        hero_by_user={@hero_by_user}
      />
    </div>
    """
  end

  attr :player, :any, default: nil
  attr :games, :any, default: nil
  attr :winner, :boolean, default: false
  attr :bye, :boolean, default: false
  attr :seed_by_user, :map, default: %{}
  attr :hero_by_user, :map, default: %{}

  defp bracket_player(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 px-2 py-1.5", @winner && "bg-success/15 font-semibold"]}>
      <span class="w-5 shrink-0 text-center text-xs text-base-content/50">
        {@player && Map.get(@seed_by_user, @player.id)}
      </span>
      <.hero_portrait
        :if={@player}
        hero={Map.get(@hero_by_user, @player && @player.id)}
        class="size-6"
      />
      <span class="flex-1 truncate">
        {(@player && @player.name) || (@bye && "(bye)") || "TBD"}
      </span>
      <span :if={is_integer(@games)} class="shrink-0 text-xs tabular-nums opacity-70">{@games}</span>
      <.icon :if={@winner} name="hero-check" class="size-4 shrink-0 text-success" />
    </div>
    """
  end

  defp bracket_winner(%{confirmed_result: "p1_win"}), do: :p1
  defp bracket_winner(%{confirmed_result: "p2_win"}), do: :p2
  defp bracket_winner(%{confirmed_result: "bye"}), do: :p1
  defp bracket_winner(_), do: nil
end
