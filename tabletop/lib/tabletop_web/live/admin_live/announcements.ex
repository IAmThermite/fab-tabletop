defmodule TabletopWeb.AdminLive.Announcements do
  @moduledoc """
  Admin console for site-wide announcements — publish one, see what is showing,
  clear it.

  The "currently showing" card reads `@system_announcement`, which
  `TabletopWeb.SystemAnnouncements` keeps live, so it tracks another admin's
  publish without this page doing anything. The history list below only
  reloads on this admin's own actions; it is a log, not a live feed.
  """
  use TabletopWeb, :live_view

  alias Tabletop.Announcements
  alias Tabletop.Announcements.Announcement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Announcements")
     |> reset_form()
     |> load_announcements()}
  end

  defp reset_form(socket) do
    changeset = Announcements.change_announcement(%Announcement{})
    assign(socket, :form, to_form(changeset))
  end

  defp load_announcements(socket) do
    assign(socket, :announcements, Announcements.list_announcements())
  end

  @impl true
  def handle_event("validate", %{"announcement" => params}, socket) do
    changeset =
      Announcements.change_announcement(
        %Announcement{},
        params,
        socket.assigns.current_scope
      )

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("publish", %{"announcement" => params}, socket) do
    case Announcements.create_announcement(socket.assigns.current_scope, params) do
      {:ok, _announcement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Announcement published.")
         |> reset_form()
         |> load_announcements()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("clear", %{"id" => id}, socket) do
    announcement = Announcements.get_announcement!(id)

    case Announcements.clear_announcement(socket.assigns.current_scope, announcement) do
      {:ok, _announcement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Announcement cleared.")
         |> load_announcements()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not clear that announcement.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    announcement = Announcements.get_announcement!(id)

    case Announcements.delete_announcement(socket.assigns.current_scope, announcement) do
      {:ok, _announcement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Announcement deleted.")
         |> load_announcements()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete that announcement.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      system_announcement={@system_announcement}
      max_width="max-w-3xl"
    >
      <.header>
        Site announcements
        <:subtitle>
          Shows a banner to everyone on the site — signed in or not. Use it for scheduled
          downtime and anything else players need to know before they sit down to a game.
        </:subtitle>
      </.header>

      <section
        :if={@system_announcement}
        class="rounded-box border-2 border-primary bg-primary/10 p-4 space-y-3"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="space-y-1">
            <h2 class="font-display text-base font-bold">Currently showing</h2>
            <p>{@system_announcement.message}</p>
            <p class="text-sm text-base-content/60">
              {level_label(@system_announcement.level)} ·
              <%= if @system_announcement.ends_at do %>
                ends <.local_datetime id="active-ends-at" at={@system_announcement.ends_at} />
              <% else %>
                no end time set
              <% end %>
            </p>
          </div>
          <button
            type="button"
            phx-click="clear"
            phx-value-id={@system_announcement.id}
            class="btn btn-sm btn-soft shrink-0"
          >
            Clear now
          </button>
        </div>
      </section>

      <.form for={@form} id="announcement-form" phx-change="validate" phx-submit="publish">
        <section class="rounded-box border border-base-300 p-4 space-y-4">
          <h2 class="font-display text-base font-bold">Publish an announcement</h2>

          <.input
            field={@form[:message]}
            type="textarea"
            label="Message"
            placeholder="Scheduled maintenance at 21:00 UTC — games in progress will disconnect."
          />

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:level]}
              type="select"
              label="Level"
              options={Announcement.level_options()}
            />
            <.input
              field={@form[:duration_minutes]}
              type="select"
              label="Show for"
              options={Announcement.duration_options()}
            />
          </div>

          <.input
            field={@form[:dismissible]}
            type="checkbox"
            label="Players can dismiss it"
          />

          <p class="text-sm text-base-content/60">
            Publishing replaces whatever is on screen now — only the newest announcement shows.
          </p>

          <.button variant="primary" phx-disable-with="Publishing…">Publish</.button>
        </section>
      </.form>

      <section class="space-y-2">
        <h2 class="font-display text-base font-bold">Recent</h2>
        <p class="text-sm text-base-content/60">
          Clearing takes an announcement off screen but keeps it here as a record — use delete to
          remove it entirely.
        </p>
        <p :if={@announcements == []} class="text-sm text-base-content/60">
          Nothing published yet.
        </p>
        <ul class="divide-y divide-base-300">
          <.announcement_row
            :for={a <- @announcements}
            announcement={a}
            showing={@system_announcement}
          />
        </ul>
      </section>
    </Layouts.app>
    """
  end

  # One row of the log. A component rather than inline markup so each state is
  # resolved once against a single `now` — inline, every `Announcements.active?/1`
  # call would re-read the clock and the badge, the Clear button and the row
  # styling could disagree with each other across a tick.
  #
  # "Live" is `showing`, not `active?/1`: only the newest in-window announcement
  # is ever on screen, and reading it from `@system_announcement` means the
  # badge follows the hook — including when a window closes on its own, which
  # produces no reload of `@announcements`.
  attr(:announcement, :map, required: true)
  attr(:showing, :map, default: nil, doc: "the announcement currently on screen, if any")

  defp announcement_row(assigns) do
    a = assigns.announcement

    assigns =
      assigns
      |> assign(:live?, assigns.showing != nil and assigns.showing.id == a.id)
      |> assign(:in_window?, Announcements.active?(a))
      |> assign(:scheduled?, DateTime.compare(a.starts_at, DateTime.utc_now()) == :gt)

    ~H"""
    <li class={[
      "flex items-start justify-between gap-3 py-3",
      not @live? && "opacity-60"
    ]}>
      <div class="space-y-1">
        <p>{@announcement.message}</p>
        <p class="text-sm text-base-content/60">
          {level_label(@announcement.level)} · started
          <.local_datetime id={"started-#{@announcement.id}"} at={@announcement.starts_at} />
          <%= if @announcement.created_by do %>
            · by {@announcement.created_by.name}
          <% else %>
            · from the console
          <% end %>
        </p>
        <%!-- The end of the window is what changes when an admin hits Clear, so
              it is spelled out rather than left to the badge alone. --%>
        <p class="text-sm text-base-content/60">
          <%= cond do %>
            <% @announcement.ends_at && @in_window? -> %>
              Ends <.local_datetime id={"ends-#{@announcement.id}"} at={@announcement.ends_at} />
            <% @announcement.ends_at -> %>
              Ended <.local_datetime id={"ends-#{@announcement.id}"} at={@announcement.ends_at} />
            <% true -> %>
              No end time set
          <% end %>
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <span class={[
          "badge badge-sm",
          @live? && "badge-primary",
          not @live? && "badge-ghost"
        ]}>
          <%= cond do %>
            <% @live? -> %>
              Live
            <% @scheduled? -> %>
              Scheduled
            <% @in_window? -> %>
              Hidden
            <% true -> %>
              Ended
          <% end %>
        </span>
        <button
          :if={@in_window?}
          type="button"
          phx-click="clear"
          phx-value-id={@announcement.id}
          class="btn btn-xs btn-soft"
        >
          Clear
        </button>
        <button
          type="button"
          phx-click="delete"
          phx-value-id={@announcement.id}
          data-confirm="Delete this announcement from the log?"
          class="btn btn-xs btn-ghost"
          aria-label="Delete announcement"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </li>
    """
  end

  defp level_label(:critical), do: "Critical"
  defp level_label(:warning), do: "Warning"
  defp level_label(_), do: "Info"
end
