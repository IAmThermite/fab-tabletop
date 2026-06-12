defmodule Tabletop.Languages do
  @moduledoc """
  The set of languages a game can be played in (and a user can prefer).

  Single source of truth shared by `Tabletop.Games.Game` and
  `Tabletop.Accounts.User`. Defined as an ordered keyword list so the display
  order is stable (English first).
  """

  # Order here drives display order in selects/filters.
  @languages [
    eng: "English",
    fra: "French",
    deu: "German",
    ita: "Italian",
    es: "Spanish",
    jpn: "Japanese",
    chi: "Chinese"
  ]

  @doc "All languages as an ordered `[{key, label}]` keyword list."
  def all, do: @languages

  @doc "The language keys (atoms). Used as the Ecto.Enum values."
  def keys, do: Keyword.keys(@languages)

  @doc "The default language (the first entry — English) for new games."
  def default, do: @languages |> hd() |> elem(0)

  @doc "Human-readable name for a language key, or `nil` if unknown/blank."
  def name(key) when is_atom(key) and not is_nil(key), do: Keyword.get(@languages, key)
  def name(_), do: nil

  @doc "Options for a `<select>`: `[{label, key}]` (label first, as Phoenix expects)."
  def options, do: Enum.map(@languages, fn {key, label} -> {label, key} end)
end
