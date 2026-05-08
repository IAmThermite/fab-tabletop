defmodule Tabletop.Cards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletop.Cards.{CardPrint, OcrNormalizer}

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "cards" do
    field :name, :string
    field :pitch, :integer
    field :external_card_id, :string
    field :normalized_name, :string
    field :tokens, {:array, :string}, default: []

    has_many :card_prints, CardPrint

    timestamps(type: :utc_datetime)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:name, :pitch, :external_card_id])
    |> validate_required([:name, :external_card_id])
    |> put_normalized_fields()
    |> unique_constraint(:external_card_id)
  end

  @doc """
  Returns the canonical print for a card — the first regular front face,
  preferring `preferred_set_code` if given. Falls back to any print.

  Returns `nil` if `card_prints` is not preloaded; callers should keep their
  own `card_print` reference as a fallback.
  """
  def canonical_print(card, preferred_set_code \\ nil)

  def canonical_print(%__MODULE__{card_prints: prints}, preferred_set_code)
      when is_list(prints) do
    canonical = Enum.filter(prints, & &1.is_canonical)

    preferred =
      preferred_set_code &&
        Enum.find(canonical, &(&1.set_code == preferred_set_code))

    cond do
      preferred -> preferred
      canonical != [] -> hd(canonical)
      prints != [] -> hd(prints)
      true -> nil
    end
  end

  def canonical_print(%__MODULE__{}, _preferred_set_code), do: nil

  defp put_normalized_fields(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        normalized = OcrNormalizer.normalize(name)
        tokens = OcrNormalizer.tokens(name)

        changeset
        |> put_change(:normalized_name, normalized)
        |> put_change(:tokens, tokens)
    end
  end
end
