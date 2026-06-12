defmodule Tabletop.Heroes do
  @moduledoc """
  The selectable hero roster and per-format legality.

  The data is baked in from `priv/heroes.json` at compile time — there is no
  runtime fetch and no database table. Regenerate the JSON and avatars with
  `mix fab.import_heroes` (see `Tabletop.Heroes.Importer`) whenever the roster
  or legality changes.

  Heroes back the format-filtered hero dropdown on the create-game form and the
  avatars shown on game tiles. A `Game.hero` stores a hero `slug`; everything
  else (display name, avatar path, legality) is looked up here.
  """

  alias Tabletop.Heroes.Hero

  @data_path Path.join([__DIR__, "..", "..", "priv", "heroes.json"])
  @external_resource @data_path

  @heroes @data_path
          |> File.read!()
          |> Jason.decode!()
          |> Enum.map(fn hero ->
            %Hero{
              slug: hero["slug"],
              name: hero["name"],
              formats: Enum.map(hero["formats"] || [], &String.to_atom/1)
            }
          end)
          |> Enum.sort_by(& &1.name)

  @by_slug Map.new(@heroes, &{&1.slug, &1})

  @doc "All heroes, ordered by display name."
  def all, do: @heroes

  @doc "The hero with the given slug, or `nil` (also `nil` for blank/non-binary input)."
  def get(slug) when is_binary(slug), do: Map.get(@by_slug, slug)
  def get(_), do: nil

  @doc "Whether `slug` is a known hero."
  def known?(slug), do: get(slug) != nil

  @doc "The display name for a hero slug, or `nil` if unknown."
  def name(slug) do
    case get(slug) do
      nil -> nil
      hero -> hero.name
    end
  end

  @doc "Heroes legal in `format` (an atom), ordered by display name."
  def legal_for(format) when is_atom(format) do
    Enum.filter(@heroes, &(format in &1.formats))
  end

  @doc "Whether the hero `slug` is legal in `format`."
  def legal?(slug, format) when is_atom(format) do
    case get(slug) do
      nil -> false
      hero -> format in hero.formats
    end
  end

  @doc "`<select>` options for a format: `[{name, slug}]` (label first, as Phoenix expects)."
  def options_for(format) when is_atom(format) do
    legal_for(format) |> Enum.map(&{&1.name, &1.slug})
  end

  @doc "Public (served) path to a hero's avatar PNG."
  def icon_path(slug) when is_binary(slug), do: "/images/heroes/#{slug}.png"
end
