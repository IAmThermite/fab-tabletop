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
    bloodrot_pox: %{
      name: "Bloodrot Pox",
      icon: "hero-beaker",
      description_html:
        "At the beginning of your end phase, destroy Bloodrot Pox, then it deals 2 damage to you unless you pay {{ resource-icon }}{{ resource-icon }}{{ resource-icon }}.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT234.webp"
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
    lose_health: %{
      name: "Lose Health",
      icon: "hero-heart-broken",
      description_html: "When this hits, lose X health.",
      counterable: true
    },
    deal_damage: %{
      name: "Deal Damage",
      icon: "hero-bolt",
      description_html: "When this hits, deal X damage to a target.",
      counterable: true
    },
    deal_arcane_damage: %{
      name: "Deal Arcane Damage",
      icon: "hero-sparkles",
      description_html: "When this hits, deal X arcane damage to a target.",
      counterable: true
    },
    draw_card: %{
      name: "Draw a Card",
      icon: "hero-rectangle-stack",
      description_html: "When this hits, draw a card."
    },
    gain_health: %{
      name: "Gain Health",
      icon: "hero-heart",
      description_html: "When this hits, gain health.",
      counterable: true
    },
    discard_from_hand: %{
      name: "Discard from Hand",
      icon: "hero-x-mark",
      description_html: "When this hits, discard a random card from your hand."
    },
    look_at_hand_and_discard: %{
      name: "Look and Discard",
      icon: "hero-eye",
      description_html:
        "When this hits, your opponent looks at your hand and chooses a card. You discard it."
    },
    look_at_hand_and_banish: %{
      name: "Look and Banish from Hand",
      icon: "hero-eye",
      description_html: "When this hits, your opponent looks at your hand and banishes a card."
    },
    look_at_top_of_deck: %{
      name: "Look at top of Deck",
      icon: "hero-eye",
      description_html: "When this hits, your opponent looks at the top cards of your deck."
    },
    destroy_top_of_deck: %{
      name: "Destroy Top of Deck",
      icon: "hero-trash",
      description_html: "When this hits, destroy the top card of your deck."
    },
    banish_and_play: %{
      name: "Banish and Play",
      icon: "hero-archive-box-arrow-down",
      description_html:
        "When this hits, banish the top card of your deck. Your opponent may play it until end of turn."
    },
    banish_top_of_deck: %{
      name: "Banish Top of Deck",
      icon: "hero-archive-box-x-mark",
      description_html: "When this hits, banish the top card of your deck."
    },
    banish_from_graveyard: %{
      name: "Banish from Graveyard",
      icon: "hero-archive-box-x-mark",
      description_html: "When this hits, your opponent banishes a card from your graveyard."
    },
    destroy_arsenal_card: %{
      name: "Destroy Arsenal",
      icon: "hero-trash",
      description_html: "When this hits, destroy a card from your arsenal."
    },
    banish_arsenal_card: %{
      name: "Banish Arsenal",
      icon: "hero-archive-box-x-mark",
      description_html: "When this hits, banish a card from your arsenal."
    },
    destroy_aura: %{
      name: "Destroy Aura",
      icon: "hero-trash",
      description_html: "When this hits, destroy an aura you control."
    },
    destroy_all_auras: %{
      name: "Destroy All Auras",
      icon: "hero-trash",
      description_html: "When this hits, destroy all auras you control."
    },
    destroy_item: %{
      name: "Destroy Item",
      icon: "hero-wrench",
      description_html: "When this hits, destroy an item you control."
    },
    create_token: %{
      name: "Create Token",
      icon: "hero-cube-transparent",
      description_html: "When this hits, create one or more tokens.",
      popup: :create_token
    }
  }

  # a list of all the tokens that a player could create for themselves via an on hit
  @tokens_map %{
    gold: %{
      name: "Gold",
      icon: "hero-currency-dollar",
      description_html:
        "<b>Action</b> – {{ resource-icon }}{{ resource-icon }}, destroy Gold: Draw a card. <b>Go again</b>",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SEN036.webp",
      for_opponent: false
    },
    silver: %{
      name: "Silver",
      icon: "hero-banknotes",
      description_html:
        "<b>Action</b> – {{ resource-icon }}{{ resource-icon }}{{ resource-icon }}, destroy Silver: Draw a card. <b>Go again</b>",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/ARK027.webp",
      for_opponent: false
    },
    copper: %{
      name: "Copper",
      icon: "hero-banknotes",
      description_html:
        "<b>Action</b> – {{ resource-icon }}{{ resource-icon }}{{ resource-icon }}{{ resource-icon }}, destroy Copper: Draw a card. <b>Go again</b>",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/CRU197.webp",
      for_opponent: false
    },
    agility: %{
      name: "Agility",
      icon: "hero-arrow-trending-up",
      description_html:
        "At the start of your turn, destroy this, then your next attack this turn gets <b>go again</b>.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SDO035.webp",
      for_opponent: false
    },
    flurry: %{
      name: "Flurry",
      icon: "hero-arrow-path-rounded-square",
      description_html:
        "When you activate a weapon attack, destroy this and you may attack with the weapon twice this turn.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/AHA027.webp",
      for_opponent: false
    },
    runechant: %{
      name: "Runechant",
      icon: "hero-sparkles",
      description_html:
        "When you play an attack action card or activate a weapon attack, destroy this and deal 1 arcane damage to target opposing hero.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SVI034.webp",
      for_opponent: false
    },
    embodiment_of_earth: %{
      name: "Embodiment of Earth",
      icon: "hero-globe-americas",
      description_html:
        "Non-attack action cards you control get +1 defense while defending.<br/>At the beginning of your action phase, destroy this.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/AJV028.webp",
      for_opponent: false
    },
    embodiment_of_lightning: %{
      name: "Embodiment of Lightning",
      icon: "hero-bolt",
      description_html:
        "When you play an attack action card, destroy this and the attack gets <b>go again</b>.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/AST028.webp",
      for_opponent: false
    },
    lightning_flow: %{
      name: "Lightning Flow",
      icon: "hero-bolt-slash",
      description_html: "Lightning Flow token.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OMN203.webp",
      for_opponent: false
    },
    might: %{
      name: "Might",
      icon: "hero-hand-raised",
      description_html:
        "At the start of your turn, destroy this, then your next attack this turn gets +1{{ power-icon }}.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SKA035.webp",
      for_opponent: false
    },
    vigor: %{
      name: "Vigor",
      icon: "hero-battery-100",
      description_html: "At the start of your turn, destroy this, then gain {{ resource-icon }}.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SDO036.webp",
      for_opponent: false
    },
    seismic_surge: %{
      name: "Seismic Surge",
      icon: "hero-globe-alt",
      description_html:
        "At the beginning of your action phase, destroy this, then the next Guardian attack action card you play this turn costs {{ resource-icon }} less to play.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SBR035.webp",
      for_opponent: false
    },
    confidence: %{
      name: "Confidence",
      icon: "hero-shield-check",
      description_html:
        "At the start of your turn, destroy this, then the next attack action card you play this turn can't be defended by more than 2 non-block cards.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/APS031.webp",
      for_opponent: false
    },
    courage: %{
      name: "Courage",
      icon: "hero-flag",
      description_html:
        "When you play an attack action card or activate a weapon attack, destroy this and the attack gets +1{{ power-icon }}.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/ASB027.webp",
      for_opponent: false
    },
    quicken: %{
      name: "Quicken",
      icon: "hero-forward",
      description_html:
        "When you play an attack action card or activate a weapon attack, destroy this and the attack gets <b>go again</b>.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/ASB028.webp",
      for_opponent: false
    },
    ponder: %{
      name: "Ponder",
      icon: "hero-light-bulb",
      description_html: "At the beginning of your end phase, destroy this and draw a card.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OSC029.webp",
      for_opponent: false
    },
    spectral_shield: %{
      name: "Spectral Shield",
      icon: "hero-shield-exclamation",
      description_html:
        "<b>Ward 1</b> <i>(If you would be dealt damage, destroy this to prevent 1 of that damage.)</i>",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SEN037.webp",
      for_opponent: false
    },
    bloodrot_pox: %{
      name: "Bloodrot Pox",
      icon: "hero-beaker",
      description_html:
        "At the beginning of your end phase, destroy Bloodrot Pox, then it deals 2 damage to you unless you pay {{ resource-icon }}{{ resource-icon }}{{ resource-icon }}.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT234.webp",
      for_opponent: true
    },
    frailty: %{
      name: "Frailty",
      icon: "hero-shield-exclamation",
      description_html: """
      <p>Your attack action cards played from arsenal and weapon attacks have -1 {{ power-icon }}.</p>
      <p>At the beginning of your end phase, destroy Frailty.</p>
      """,
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT235.webp",
      for_opponent: true
    },
    inertia: %{
      name: "Inertia",
      icon: "hero-no-symbol",
      description_html:
        "At the beginning of your end phase, destroy Inertia, then put all cards from your hand and arsenal on the bottom of your deck.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT236.webp",
      for_opponent: true
    },
    mark: %{
      name: "Mark",
      icon: "hero-map-pin",
      description_html: "You are <b>marked</b> until an opponent hits you.",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/AAC031.webp",
      for_opponent: true
    },
    frostbite: %{
      name: "Frostbite",
      icon: "hero-cube-transparent",
      description_html: """
      <p>Cards and activated abilities you control cost an additional {{ resource-icon }}.</p>
      <p>At the beginning of your end phase or when you play a card or activate an ability, destroy Frostbite.</p>
      """,
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/ELE111.webp",
      for_opponent: true
    },
    # you can generate a gold for your opponent so lets add it here too
    gold_2: %{
      name: "Gold",
      icon: "hero-currency-dollar",
      description_html: "<b>Action</b> – {{ resource-icon }}{{ resource-icon }}, destroy Gold: Draw a card. <b>Go again</b>",
      card_img_src:
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SEN036.webp",
      for_opponent: true
    }
  }

  def abilities, do: @abilities_map
  def on_hit_effects, do: @on_hit_effects_map
  def tokens, do: @tokens_map
  def tokens_for_player, do: Enum.filter(@tokens_map, fn {_k, t} -> !t.for_opponent end)
  def tokens_for_opponent, do: Enum.filter(@tokens_map, fn {_k, t} -> t.for_opponent end)

  def counterable?("ability", name) do
    Enum.any?(@abilities_map, fn {_k, e} ->
      e[:name] == name and Map.get(e, :counterable, false)
    end)
  end

  def counterable?("on_hit", name) do
    Enum.any?(@on_hit_effects_map, fn {_k, e} ->
      e[:name] == name and Map.get(e, :counterable, false)
    end)
  end

  def counterable?(_, _), do: false

  def valid_token?(name) do
    Enum.any?(@tokens_map, fn {_k, t} -> t.name == name end)
  end

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
