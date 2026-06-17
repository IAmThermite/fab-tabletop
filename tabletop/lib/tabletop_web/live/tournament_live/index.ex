defmodule TabletopWeb.TournamentLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Tournaments
  alias Tabletop.Tournaments.Tournament
  alias Tabletop.Accounts.Scope

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tournaments.subscribe_tournaments()

    {:ok,
     socket
     |> assign(:page_title, "Tournaments")
     |> assign_tournaments()}
  end

  @impl true
  def handle_info({:tournaments_updated}, socket) do
    {:noreply, assign_tournaments(socket)}
  end

  # Groups tournaments into display sections. Draft tournaments are admin-only.
  # `list_tournaments/0` already orders by status then recency, so each section
  # keeps a sensible order.
  defp assign_tournaments(socket) do
    admin? = Scope.admin?(socket.assigns.current_scope)
    all = Tournaments.list_tournaments()
    visible = if admin?, do: all, else: Enum.reject(all, &(&1.status == :draft))

    sections = [
      {"Upcoming", Enum.filter(visible, &(&1.status in [:draft, :registration, :check_in]))},
      {"In progress", Enum.filter(visible, &(&1.status in [:swiss, :cut]))},
      {"Finished", Enum.filter(visible, &(&1.status in [:finished, :cancelled]))}
    ]

    socket
    |> assign(:sections, sections)
    |> assign(:sections_empty?, Enum.all?(sections, fn {_label, ts} -> ts == [] end))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-4xl">
      <.header>
        Tournaments
        <:subtitle>Browse and join Flesh and Blood tournaments.</:subtitle>
        <:actions :if={Scope.admin?(@current_scope)}>
          <.button navigate={~p"/tournaments/new"} variant="primary">New Tournament</.button>
        </:actions>
      </.header>

      <.notification_banners items={@notification_items} />

      <div :if={@sections_empty?} class="text-center py-16 opacity-60">
        <.icon name="hero-trophy" class="size-10 mx-auto mb-3 opacity-40" />
        <p>No tournaments yet.</p>
      </div>

      <section :for={{label, tournaments} <- @sections} :if={tournaments != []} class="mb-8">
        <h2 class="font-display text-xl font-bold mb-3 flex items-center gap-2">
          {label}
          <span class="badge badge-sm badge-neutral">{length(tournaments)}</span>
        </h2>
        <div class="grid gap-3 sm:grid-cols-2">
          <.tournament_card :for={t <- tournaments} tournament={t} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :tournament, :any, required: true

  defp tournament_card(assigns) do
    t = assigns.tournament
    assigns = assign(assigns, :filling?, t.status in [:registration, :check_in])

    ~H"""
    <.link
      navigate={~p"/tournaments/#{@tournament}"}
      class="group block rounded-box border border-base-300 p-4 transition-colors hover:bg-base-200"
    >
      <div class="flex items-start justify-between gap-3">
        <h3 class="font-display text-lg font-bold leading-tight truncate group-hover:text-primary">
          {@tournament.name}
        </h3>
        <.tournament_status_badge status={@tournament.status} class="shrink-0" />
      </div>

      <div class="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-base-content/70">
        <span class="badge badge-sm badge-ghost">{Tournament.format_name(@tournament)}</span>
        <span>{@tournament.active_player_count}/{@tournament.max_players} players</span>
      </div>

      <progress
        :if={@filling?}
        class="progress progress-primary mt-2 w-full max-w-[14rem]"
        value={@tournament.active_player_count}
        max={@tournament.max_players}
      >
      </progress>

      <p :if={@tournament.starts_at} class="mt-2 text-sm text-base-content/70">
        <span class="opacity-70">Starts</span>
        <.local_datetime
          id={"tournament-#{@tournament.id}-starts-at"}
          at={@tournament.starts_at}
          countdown={@tournament.status in [:draft, :registration]}
        />
      </p>
    </.link>
    """
  end
end
