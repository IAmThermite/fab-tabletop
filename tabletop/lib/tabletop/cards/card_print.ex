defmodule Tabletop.Cards.CardPrint do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletop.Cards.{Card, PHash}

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
    field :image_phash_left, :integer
    field :image_phash_right, :integer
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
      :image_phash_left,
      :image_phash_right,
      :image_phash_full
    ])
    |> validate_required([:card_id, :face_id, :image_url, :orientation])
    |> unique_constraint(:face_id)
  end

  @doc """
  Computes pHashes and writes them onto the changeset based on `orientation`
  and the `art_bbox` ratios. `art_bbox` is either a single `{x, y, w, h}` map
  (vertical) or a 2-element list of such maps (horizontal halves).
  """
  def put_image_phashes(changeset, opts \\ []) do
    image_url = get_field(changeset, :image_url)
    orientation = get_field(changeset, :orientation)
    bbox = get_field(changeset, :art_bbox)
    req_options = Keyword.get(opts, :req_options, [])

    cond do
      is_nil(image_url) ->
        changeset

      orientation == "vertical" and is_map(bbox) and Map.has_key?(bbox, :x) ->
        art = PHash.compute(image_url, bbox: bbox_tuple(bbox), req_options: req_options)
        full = PHash.compute(image_url, bbox: {0.0, 0.0, 1.0, 1.0}, req_options: req_options)

        changeset
        |> put_change(:image_phash, art)
        |> put_change(:image_phash_full, full)

      orientation == "horizontal" and is_map(bbox) and Map.has_key?(bbox, :halves) ->
        [left, right | _] = bbox[:halves] || bbox["halves"]
        h_left = PHash.compute(image_url, bbox: bbox_tuple(left), req_options: req_options)
        h_right = PHash.compute(image_url, bbox: bbox_tuple(right), req_options: req_options)
        full = PHash.compute(image_url, bbox: {0.0, 0.0, 1.0, 1.0}, req_options: req_options)

        changeset
        |> put_change(:image_phash_left, h_left)
        |> put_change(:image_phash_right, h_right)
        |> put_change(:image_phash_full, full)

      true ->
        changeset
    end
  end

  defp bbox_tuple(%{"x" => x, "y" => y, "w" => w, "h" => h}), do: {x, y, w, h}
  defp bbox_tuple(%{x: x, y: y, w: w, h: h}), do: {x, y, w, h}
end
