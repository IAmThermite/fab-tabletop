defmodule Tabletop.Cards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "cards" do
    field :name, :string
    field :image_url, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:name, :image_url])
    |> validate_required([:name, :image_url])
  end
end
