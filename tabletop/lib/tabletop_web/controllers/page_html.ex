defmodule TabletopWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use TabletopWeb, :html

  embed_templates("page_html/*")

  @doc """
  One collapsible question/answer row in the about page's FAQ.

  A native `<details>`/`<summary>` drives the collapse rather than JavaScript,
  matching the lobby's intro and format groups: the answer stays in the page
  source for search engines, and keyboard and screen-reader users get the
  browser's own disclosure behaviour with nothing to reimplement.
  """
  attr(:question, :string, required: true)
  slot(:inner_block, required: true)

  def faq_item(assigns) do
    ~H"""
    <details class="group rounded-box border border-base-300 bg-base-200/40">
      <summary class="flex cursor-pointer list-none select-none items-center justify-between gap-3 p-4 text-lg font-semibold">
        <span>{@question}</span>
        <.icon
          name="hero-chevron-down"
          class="size-5 shrink-0 text-primary transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="space-y-3 px-4 pb-4">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end
end
