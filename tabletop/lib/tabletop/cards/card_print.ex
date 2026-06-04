defmodule Tabletop.Cards.CardPrint do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletop.Cards.Card

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id

  schema "card_prints" do
    belongs_to :card, Card, type: :binary_id

    field :face_id, :string
    field :set_code, :string
    field :art_type, :string
    field :orientation, :string
    field :layout_position, :integer
    field :is_canonical, :boolean, default: true
    field :image_url, :string
    field :art_bbox, :map
    field :image_phash, :integer
    field :image_phash_full, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(card_print, attrs) do
    card_print
    |> cast(attrs, [
      :card_id,
      :face_id,
      :set_code,
      :art_type,
      :orientation,
      :layout_position,
      :is_canonical,
      :image_url,
      :art_bbox,
      :image_phash,
      :image_phash_full
    ])
    |> validate_required([:card_id, :face_id, :image_url, :orientation])
    |> unique_constraint(:face_id)
  end
end
