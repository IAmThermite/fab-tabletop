defmodule Tabletop.Cards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletop.Cards.OcrNormalizer

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "cards" do
    field :name, :string
    field :print_id, :string
    field :normalized_name, :string
    field :tokens, {:array, :string}, default: []
    field :image_url, :string
    field :image_phash, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def import_changeset(card, attrs) do
    card
    |> cast(attrs, [:name, :print_id, :image_url])
    |> validate_required([:name, :print_id, :image_url])
    |> put_normalized_fields()
    |> put_image_phash()
  end

  def generated_changeset(card, attrs) do
    card
    |> cast(attrs, [:name, :print_id, :image_url, :tokens, :normalized_name, :image_phash])
    |> validate_required([:name, :print_id, :image_url, :tokens, :normalized_name, :image_phash])
  end

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

  defp put_image_phash(changeset) do
    case get_change(changeset, :image_url) do
      nil ->
        changeset

      image_url ->
        phash = Tabletop.Cards.PHash.compute(image_url)
        put_change(changeset, :image_phash, phash)
    end
  end
end
