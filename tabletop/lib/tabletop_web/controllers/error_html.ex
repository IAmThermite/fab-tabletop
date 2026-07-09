defmodule TabletopWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use TabletopWeb, :html

  # Stylized pages live in error_html/{404,500}.html.heex and compile to the
  # `:"404"/1` and `:"500"/1` functions Phoenix renders for those statuses.
  #
  # They are FULL, standalone HTML documents on purpose: errors render with
  # `layout: false` (see the :render_errors config), so there is no root layout
  # to wrap them, and a 500 can fire before the browser pipeline runs — meaning
  # app assigns (`@csp_nonce`, `@flash`, …) may be absent. So the pages depend on
  # nothing but the compiled CSS and Google Fonts (both CSP-allowed) and use no
  # JavaScript; the theme is pinned to the dark `halloween` default.
  embed_templates("error_html/*")

  @doc """
  Shared chrome for the stylized error pages.

  Renders the full HTML document — fonts, compiled CSS, logo, the red/yellow/blue
  pitch accent bar — and leaves the heading, flavour text, and action buttons to
  the calling template via attrs and slots.
  """
  attr(:status, :integer, required: true, doc: "HTTP status, shown as the eyebrow")
  attr(:title, :string, required: true, doc: "the large display heading")
  attr(:page_title, :string, required: true, doc: "contents of the <title> tag")
  slot(:flavor, required: true, doc: "Flesh and Blood flavour line, rendered in quotes")
  slot(:actions, required: true, doc: "call-to-action buttons")

  def error_shell(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="halloween">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@page_title} · FaB Tabletop</title>
        <link rel="icon" type="image/svg+xml" href={~p"/images/logo-mark.svg"} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Cinzel:wght@600;700&family=Inter:wght@400;500;600;700&display=swap"
        />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body class="min-h-screen bg-gradient-to-b from-base-100 to-base-200 text-base-content">
        <main class="grid min-h-screen place-items-center px-4 py-16">
          <div class="w-full max-w-xl space-y-8 text-center">
            <a href={~p"/"} class="inline-flex justify-center" aria-label="FaB Tabletop home">
              <img src={~p"/images/logo-mark.svg"} alt="FaB Tabletop" class="h-16 w-auto" />
            </a>

            <div class="space-y-3">
              <p class="font-display text-sm uppercase tracking-[0.35em] text-base-content/50">
                Error {@status}
              </p>
              <h1 class="font-display text-5xl font-bold sm:text-7xl">{@title}</h1>
            </div>

            <div class="flex justify-center gap-1.5" aria-hidden="true">
              <span class="h-1.5 w-10 rounded-full bg-pitch-red"></span>
              <span class="h-1.5 w-10 rounded-full bg-pitch-yellow"></span>
              <span class="h-1.5 w-10 rounded-full bg-pitch-blue"></span>
            </div>

            <p class="mx-auto max-w-md text-lg italic leading-relaxed text-base-content/70 sm:text-xl">
              &ldquo;{render_slot(@flavor)}&rdquo;
            </p>

            <div class="flex flex-wrap justify-center gap-3 pt-2">
              {render_slot(@actions)}
            </div>
          </div>
        </main>
      </body>
    </html>
    """
  end

  # Fallback for any status without a dedicated template above — renders the
  # plain status message ("Forbidden", "Bad Request", …) like the default.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
