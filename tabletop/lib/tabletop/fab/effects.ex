defmodule Tabletop.Fab.Effects do
  @moduledoc """
  Catalog of Fab abilities and on-hit effects.

  Descriptions are plain HTML strings. Inline icons can be embedded with
  `{{ icon-name }}` placeholders (e.g. `{{ power-icon }}`), which are
  expanded to `<img>` tags by `render_description/1` at render time.
  """

  @abilities_map %{
    dominate: %{
      name: "Dominate",
      icon: "hero-hand-raised",
      description_html: "This can't be defended by more than one card from hand."
    },
    overpower: %{
      name: "Overpower",
      icon: "hero-fire",
      description_html: "This can't be defended by more than one action card."
    }
  }

  @on_hit_effects_map %{
    go_again: %{
      name: "Go Again",
      icon: "hero-arrow-path",
      description_html: "When this hits, gain an action point."
    },
    mark: %{
      name: "Mark",
      icon: "hero-map-pin",
      description_html: "You are <b>marked</b> until an opponent hits you.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/AAC031.webp"
    },
    frostbite: %{
      name: "Frostbite",
      icon: "hero-cube-transparent",
      description_html: """
      <p>Cards and activated abilities you control cost an additional {{ resource-icon }}.</p>
      <p>At the beginning of your end phase or when you play a card or activate an ability, destroy Frostbite.</p>
      """,
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/ELE111.webp"
    },
    frailty: %{
      name: "Frailty",
      icon: "hero-shield-exclamation",
      description_html: """
      <p>Your attack action cards played from arsenal and weapon attacks have -1 {{ power-icon }}.</p>
      <p>At the beginning of your end phase, destroy Frailty.</p>
      """,
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT235.webp"
    },
    inertia: %{
      name: "Inertia",
      icon: "hero-no-symbol",
      description_html:
        "At the beginning of your end phase, destroy Inertia, then put all cards from your hand and arsenal on the bottom of your deck.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT236.webp"
    },
    bloodrot_pox: %{
      name: "Bloodrot Pox",
      icon: "hero-beaker",
      description_html:
        "At the beginning of your end phase, destroy Bloodrot Pox, then it deals 2 damage to you unless you pay {{ resource-icon }}{{ resource-icon }}{{ resource-icon }}.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT234.webp"
    }
  }

  def abilities, do: @abilities_map
  def on_hit_effects, do: @on_hit_effects_map

  @inline_icons %{
    "power-icon" => "/images/fab/power-icon.png",
    "resource-icon" => "/images/fab/resource-icon.png",
    "health-icon" => "/images/fab/health-icon.png"
  }

  @doc """
  Expands `{{ icon-name }}` placeholders inside a description string into
  `<img>` tags. Whitespace inside the braces is optional. Unknown icon names
  are left untouched so typos are visible.
  """
  def render_description(nil), do: nil
  def render_description(""), do: ""

  def render_description(html) when is_binary(html) do
    Regex.replace(~r/\{\{\s*([a-z0-9-]+)\s*\}\}/, html, fn whole, name ->
      case Map.fetch(@inline_icons, name) do
        {:ok, src} ->
          ~s(<img src="#{src}" alt="#{name}" class="inline-block size-4 align-text-bottom" />)

        :error ->
          whole
      end
    end)
  end
end
