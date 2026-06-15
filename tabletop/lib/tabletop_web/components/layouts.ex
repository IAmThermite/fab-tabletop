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

  attr(:max_width, :string, default: "max-w-2xl", doc: "the max width class for the main content")

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
    <div class="flex min-h-screen flex-col">
      <header class="navbar gap-2 border-b border-base-300 bg-base-100/90 backdrop-blur px-4 sm:px-6 lg:px-8">
        <div class="flex-1">
          <.link navigate={~p"/"} class="inline-flex items-center gap-3">
            <img src={~p"/images/logo.png"} alt="FaB Tabletop" class="h-12 w-auto" />
            <span class="font-display text-xl font-bold tracking-wide hidden sm:inline">
              FaB Tabletop
            </span>
          </.link>
        </div>

        <div class="flex items-center gap-1">
          <.link navigate={~p"/about"} class="btn btn-ghost btn-sm">About</.link>

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
                <li><.link href={~p"/users/log-out"} method="delete">Log out</.link></li>
              </ul>
            </div>
          <% else %>
            <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
            <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">Register</.link>
          <% end %>
        </div>
      </header>

      <main class="flex-1 px-3 sm:px-6 lg:px-8 pt-6 sm:pt-8">
        <div class={["mx-auto space-y-4", @max_width]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <.site_footer />
    </div>

    <.flash_group flash={@flash} />
    """
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
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6 flex flex-col sm:flex-row items-center justify-between gap-4 text-sm">
        <span class="font-display font-bold text-base-content/70">FaB Tabletop</span>

        <nav class="flex items-center gap-4 text-base-content/70">
          <.link navigate={~p"/about"} class="link link-hover">About</.link>
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

  slot(:inner_block, required: true)

  def game(assigns) do
    ~H"""
    <main class="fixed inset-0 z-20 overflow-hidden">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
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
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=cupcake]_&]:left-1/3 [[data-theme=halloween]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="cupcake"
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
