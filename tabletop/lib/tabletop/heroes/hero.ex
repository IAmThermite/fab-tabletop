defmodule Tabletop.Heroes.Hero do
  @moduledoc """
  A selectable Flesh and Blood hero.

    * `slug` — kebab-case of the full name; the value stored in `Game.hero`
      and the avatar filename (`priv/static/images/heroes/<slug>.png`).
    * `name` — full display name, e.g. `"Hala, Bladesaint of the Vow"`.
    * `formats` — the app format atoms the hero is legal in
      (subset of `:classic_constructed`, `:blitz`, `:silver_age`, `:living_legend`).
  """

  @enforce_keys [:slug, :name]
  defstruct [:slug, :name, formats: []]
end
