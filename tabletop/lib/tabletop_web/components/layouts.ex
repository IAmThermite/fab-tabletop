defmodule TabletopWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TabletopWeb, :html

  # Community links surfaced in the navbar/footer.
  # TODO: replace with the real invite/repo URLs.
  @discord_url "https://discord.gg/25QAegj6gJ"
  @github_url "https://github.com/IAmThermite/fab-tabletop"
  @patreon_url "https://patreon.com/c/FaBTabletop"

  @doc """
  Invite link for the community Discord — the primary contact channel named by
  the policy pages, which read it from here rather than hard-coding a copy.
  """
  def discord_url, do: @discord_url

  @doc """
  Public source repository, and the written-record contact channel named by the
  policy pages.
  """
  def github_url, do: @github_url

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  attr(:max_width, :string, default: "max-w-4xl", doc: "the max width class for the main content")

  attr(:system_announcement, :map,
    default: nil,
    doc: "the active site-wide announcement, from `TabletopWeb.SystemAnnouncements`"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    current_game =
      case assigns[:current_scope] do
        %{} = scope -> Tabletop.Games.get_current_game_for_user(scope)
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:current_game, current_game)
      |> assign(:discord_url, @discord_url)
      |> assign(:github_url, @github_url)
      |> assign(:patreon_url, @patreon_url)

    ~H"""
    <%!-- Full-page hero-selection backdrop shared by every standard page: a
         random Flesh and Blood scene texture (see background_image/0). A fixed
         layer behind all content (-z-10) so it stays put while the page scrolls
         and covers the whole viewport (bg-cover) with no letterboxing. Sized
         with h-screen/w-screen (100vh/100vw) rather than inset-0 on purpose:
         inset-0 stops at the scrollbar gutters, leaving a strip of the base-100
         <html> background showing at the edges; 100vh/100vw span the gutters
         too, and a fixed element doesn't add to scroll width so this creates no
         scrollbars. `phx-update="ignore"` freezes the image chosen by the dead
         render so a LiveView's connected mount (which re-picks) doesn't swap it
         out and flash a different image. --%>
    <div
      id="page-backdrop"
      phx-update="ignore"
      aria-hidden="true"
      class="fixed top-0 left-0 -z-10 h-screen w-screen bg-cover bg-center bg-no-repeat"
      style={"background-image: url('#{background_image()}')"}
    >
    </div>
    <div class="flex min-h-screen flex-col">
      <%!-- `relative z-30` is load-bearing. `backdrop-blur` makes this header its
           own stacking context, which traps the user-menu dropdown inside it —
           the dropdown's z-index is then only ever compared against the header's
           other children, never against the page. The main content panel below
           is a stacking context for the same reason and comes later in the DOM,
           so without an explicit z-index here it paints over the open dropdown. --%>
      <header class="navbar relative z-30 gap-2 border-b border-base-300 bg-base-100/40 backdrop-blur px-4 sm:px-6 lg:px-8">
        <div class="flex-1">
          <.link navigate={~p"/"} class="inline-flex items-center gap-3">
            <img src={~p"/images/banner.png"} alt="FaB Tabletop" class="h-12 w-auto" />
          </.link>
        </div>

        <div class="flex items-center gap-4">
          <.link navigate={~p"/tournaments"} class="btn btn-ghost">
            Tournaments
          </.link>
          <.link navigate={~p"/about"} class="btn btn-ghost">
            About
          </.link>

          <a
            href={@discord_url}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Join us on Discord"
            title="Discord"
          >
            <.discord_icon class="size-5" />
          </a>
          <a
            href={@github_url}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="View the source on GitHub"
            title="GitHub"
          >
            <.github_icon class="size-5" />
          </a>
          <a
            href={@patreon_url}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Support us on Patreon"
            title="Patreon"
          >
            <.patreon_icon class="size-5" />
          </a>

          <.theme_toggle />

          <%= if @current_scope do %>
            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1">
                <.icon name="hero-user-circle" class="size-5" />
                <span class="hidden sm:inline max-w-32 truncate">{@current_scope.user.name}</span>
                <.icon name="hero-chevron-down" class="size-4 opacity-60" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu bg-base-100 rounded-box z-50 mt-2 w-44 p-2 shadow-lg border border-base-300"
              >
                <li><.link href={~p"/users/settings"}>Settings</.link></li>
                <li :if={Tabletop.Accounts.Scope.admin?(@current_scope)}>
                  <.link navigate={~p"/admin/announcements"}>Announcements</.link>
                </li>
                <li><.link href={~p"/users/log-out"} method="delete">Log out</.link></li>
              </ul>
            </div>
          <% else %>
            <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
            <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">Register</.link>
          <% end %>
        </div>
      </header>

      <main class="flex-1 px-3 sm:px-6 lg:px-8 pt-6 sm:pt-8 pb-10 sm:pb-12">
        <%!-- Content sits on a slightly transparent base-background panel so it stays readable
             over the backdrop image. The panel hugs its content (no forced
             height) and is centred at the page's max width, leaving the image
             visible in the surrounding margins. --%>
        <div class={["mx-auto", @max_width]}>
          <%!-- Sits above the content panel rather than inside it so it reads as
               chrome, and so it is the first thing under the header on every
               standard page. The game layout uses the toast variant instead. --%>
          <.system_announcement announcement={@system_announcement} />
          <div class="space-y-4 rounded-box border border-base-300 bg-base-100/80 backdrop-blur p-4 sm:p-6">
            {render_slot(@inner_block)}
          </div>
        </div>
      </main>

      <.site_footer />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Picks one page backdrop at random. Rendered by `app/1` and re-picked per
  render, but `phx-update="ignore"` on the backdrop element keeps whichever
  image the dead render chose, so a visitor sees one random scene per page load.
  """
  def background_image, do: Enum.random(background_images())

  @doc """
  De-duplicated set of Flesh and Blood hero-selection scene textures, saved from
  fabtcg.com/hero-selection (several heroes share a scene). These back the random
  full-page backdrop applied to every standard page via `app/1`.
  """
  def background_images do
    [
      ~p"/images/hero-backgrounds/aria_candlehold_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/aria_isenloft_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/aria_volthaven_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/BG_OMN_HEROSELECTOR-scaled.jpg",
      ~p"/images/hero-backgrounds/deathmatch_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/demonastery_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/Everfest_BG.webp",
      ~p"/images/hero-backgrounds/high_seas_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/metrix_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/misteria_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/pits_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/savage_lands_bg-scaled-1.jpg",
      ~p"/images/hero-backgrounds/solana_bg-scaled-2.jpg",
      ~p"/images/hero-backgrounds/volcor_bg-scaled-1.jpg"
    ]
  end

  @doc """
  Site footer with community links.
  Rendered on standard app pages (not the fullscreen in-game layout).
  """
  def site_footer(assigns) do
    assigns =
      assigns
      |> assign(:discord_url, @discord_url)
      |> assign(:github_url, @github_url)
      |> assign(:patreon_url, @patreon_url)

    ~H"""
    <footer class="border-t border-base-300 bg-base-200/40">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6 space-y-4 text-sm">
        <div class="flex flex-col sm:flex-row items-center justify-between gap-4">
          <span class="font-display font-bold text-base-content/70">FaB Tabletop</span>

          <nav class="flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-base-content/70">
            <.link navigate={~p"/about"} class="link link-hover">About</.link>
            <.link navigate={~p"/privacy"} class="link link-hover">Privacy</.link>
            <.link navigate={~p"/terms"} class="link link-hover">Terms</.link>
            <.link navigate={~p"/code-of-conduct"} class="link link-hover">Code of Conduct</.link>
            <a href={@discord_url} target="_blank" rel="noopener noreferrer" class="link link-hover">
              Discord
            </a>
            <a href={@github_url} target="_blank" rel="noopener noreferrer" class="link link-hover">
              GitHub
            </a>
            <a href={@patreon_url} target="_blank" rel="noopener noreferrer" class="link link-hover">
              Patreon
            </a>
          </nav>
        </div>

        <p class="text-xs leading-relaxed text-base-content/50 text-center sm:text-left">
          Fab Tabletop is in no way affiliated with Legend Story Studios. Flesh and Blood™, and set names are trademarks of Legend Story Studios®.
        </p>
      </div>
    </footer>
    """
  end

  attr :class, :string, default: "size-5"

  defp discord_icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z" />
    </svg>
    """
  end

  attr :class, :string, default: "size-5"

  defp github_icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222 0 1.606-.014 2.898-.014 3.293 0 .322.216.694.825.576C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
    """
  end

  attr :class, :string, default: "size-5"

  defp patreon_icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M0 .48v23.04h4.22V.48zm15.385 0c-4.764 0-8.641 3.88-8.641 8.65 0 4.755 3.877 8.623 8.641 8.623 4.75 0 8.615-3.868 8.615-8.623C24 4.36 20.136.48 15.385.48z" />
    </svg>
    """
  end

  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  attr(:system_announcement, :map,
    default: nil,
    doc: "the active site-wide announcement, from `TabletopWeb.SystemAnnouncements`"
  )

  slot(:inner_block, required: true)

  def game(assigns) do
    ~H"""
    <main class="fixed inset-0 z-20 overflow-hidden">
      {render_slot(@inner_block)}
    </main>

    <%!-- No `flash_group/1` here: its toasts park over the video grid. The tray
         collects the same alerts behind one corner button instead. --%>
    <.game_alert_tray flash={@flash} system_announcement={@system_announcement} />
    <.notification_sounds />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>

    <.notification_sounds />
    """
  end

  @doc """
  Every alert the game view can raise, collapsed into one corner button.

  The game layout is a fullscreen video grid: a toast parked over it hides the
  thing the player is actually looking at, and the system announcement in
  particular stays up until dismissed. So instead of floating cards, this puts
  a single small button bottom-right with an unread count, and the alerts
  themselves in a panel that only opens when the player asks for it.

  **Connection loss is deliberately not in the panel.** `#connection-status` in
  the game top bar tracks the *WebRTC peer*, not the LiveView socket, so these
  two are the only signal that the socket itself has dropped — and a dropped
  socket is exactly when nothing can prompt the player to open a tray. They
  render as compact pills beside the button instead: still unmissable, still
  small enough not to obstruct.

  Tray entries do not auto-hide the way `flash_group/1`'s toasts do. An alert
  that erased itself after five seconds would leave the unread count lying, and
  the whole point of collapsing them is that they wait until they're read.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:system_announcement, :map,
    default: nil,
    doc: "the active site-wide announcement, from `TabletopWeb.SystemAnnouncements`"
  )

  def game_alert_tray(assigns) do
    ~H"""
    <div
      id="game-alert-tray"
      phx-hook=".AlertTray"
      class="fixed bottom-4 right-4 z-[60] flex flex-col items-end gap-2"
    >
      <%!-- Hidden until the hook finds something in it, so an empty tray puts
            nothing at all over the video. `aria-live` is on the panel rather
            than the button so a screen reader announces the alert text itself. --%>
      <div
        id="game-alert-panel"
        data-panel
        hidden
        aria-live="polite"
        class="flex w-80 max-w-[calc(100vw-2rem)] flex-col gap-2"
      >
        <.system_announcement announcement={@system_announcement} variant={:tray} />
        <.flash kind={:info} flash={@flash} variant={:tray} />
        <.flash kind={:error} flash={@flash} variant={:tray} />
      </div>

      <div
        id="client-error"
        role="alert"
        hidden
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        class="alert alert-error w-auto gap-2 px-3 py-2 shadow-lg"
      >
        <.icon name="hero-arrow-path" class="size-4 shrink-0 motion-safe:animate-spin" />
        <span class="text-sm">{gettext("Reconnecting…")}</span>
      </div>

      <div
        id="server-error"
        role="alert"
        hidden
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        class="alert alert-error w-auto gap-2 px-3 py-2 shadow-lg"
      >
        <.icon name="hero-arrow-path" class="size-4 shrink-0 motion-safe:animate-spin" />
        <span class="text-sm">{gettext("Something went wrong — reconnecting…")}</span>
      </div>

      <button
        data-toggle
        type="button"
        hidden
        aria-expanded="false"
        aria-controls="game-alert-panel"
        class="btn btn-circle btn-sm indicator"
        title={gettext("Alerts")}
      >
        <span data-count class="indicator-item badge badge-xs badge-primary"></span>
        <.icon name="hero-bell" class="size-5" />
      </button>
    </div>
    <script :type={ColocatedHook} name=".AlertTray">
      export default {
        mounted() {
          this.el.querySelector("[data-toggle]").addEventListener("click", () => this.toggle())

          // Not every alert leaves through the server. Dismissing the
          // announcement is a localStorage note the hook applies by setting
          // `hidden`, and clearing a flash hides it with a JS transition before
          // the round trip lands — neither produces a patch here, so without
          // this the badge would keep counting alerts that are already gone.
          this._observer = new MutationObserver(() => this.sync())
          this._observer.observe(this.panel(), {
            subtree: true,
            childList: true,
            attributeFilter: ["hidden", "style", "class"],
          })

          this.sync()
        },

        destroyed() { this._observer?.disconnect() },

        // Recomputed from the DOM rather than tracked, so server-sent and
        // client-side removals are counted the same way.
        updated() { this.sync() },

        toggle() {
          this.setOpen(this.panel().hidden)
        },

        setOpen(open) {
          this.panel().hidden = !open
          this.el.querySelector("[data-toggle]").setAttribute("aria-expanded", String(open))
        },

        sync() {
          const count = this.visibleAlerts().length
          const button = this.el.querySelector("[data-toggle]")

          this.el.querySelector("[data-count]").textContent = count
          button.hidden = count === 0

          // An emptied tray closes itself; leaving an open, empty panel over
          // the video is the obstruction this whole component exists to avoid.
          if (count === 0) this.setOpen(false)

          // Nudge, don't interrupt: something new is worth noticing, but
          // opening the panel would put a card back over the board.
          if (count > this._lastCount) {
            button.classList.remove("motion-safe:animate-bounce")
            void button.offsetWidth
            button.classList.add("motion-safe:animate-bounce")
            setTimeout(() => button.classList.remove("motion-safe:animate-bounce"), 1500)
          }
          this._lastCount = count
        },

        visibleAlerts() {
          return [...this.panel().querySelectorAll("[data-alert]")].filter(
            (el) => !el.hidden && getComputedStyle(el).display !== "none"
          )
        },

        panel() { return this.el.querySelector("[data-panel]") },
      }
    </script>
    """
  end

  @doc """
  Plays the audio cue that accompanies a notification toast. Rendered by both
  layouts, and listening on its own event so it never collides with the in-game
  `#game-sounds` hook, which owns `play_sound`.
  """
  def notification_sounds(assigns) do
    ~H"""
    <div id="notification-sounds" phx-hook=".NotificationSounds"></div>
    <script :type={ColocatedHook} name=".NotificationSounds">
      import { sounds } from "@/js/sounds.js"

      export default {
        mounted() {
          sounds.unlock()
          this.handleEvent("play_notification_sound", ({ cue }) => sounds.play(cue))
        },
      }
    </script>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=garden]_&]:left-1/3 [[data-theme=halloween]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="garden"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="halloween"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
