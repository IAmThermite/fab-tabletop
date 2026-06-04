defmodule Tabletop.Cards.ArtBboxDetector do
  @moduledoc """
  Computes the art-region bounding box for a printed FaB card image.

  Returns either:
    * `%{x, y, w, h}` — ratios in 0..1, the region to crop for the `art` pHash.
    * `nil` — no art crop applies; the importer will only compute the
      whole-card `image_phash_full`.

  Horizontal (landscape) cards return `nil`: the cardvault `_large` images for
  horizontal cards are stored portrait (rotated 90° CCW), and the vertical art
  ratios don't correspond to any meaningful region of the rotated card, so a
  stored `image_phash` for them would just be noise. These cards are matched
  via `image_phash_full` only.

  The implementation uses fixed ratios per (`orientation`, `art_type`); a
  contour-based attempt didn't reliably outperform them on the canonical sample
  (Arakni / Everbloom / Great Library / Chum).
  """

  @regular %{x: 0.10, y: 0.16, w: 0.80, h: 0.42}

  @doc """
  Compute the art bbox for a card image.

    * `image_binary` – raw bytes of the printed card image.
    * `meta` – at least `:orientation` (`"vertical"` | `"horizontal"`) and
      `:art_type` (`"regular"` | `"extended-art"` | `"full-art"`).

  Returns `%{x, y, w, h}` for vertical cards, or `nil` for horizontal (no art
  crop — match via `image_phash_full` only).
  """
  @spec detect(binary(), map()) :: map() | nil
  def detect(_image_binary, %{orientation: "vertical", art_type: art_type}) do
    art_region(art_type)
  end

  def detect(_image_binary, %{orientation: "horizontal"}), do: nil

  # Fallback for unexpected orientations (e.g. the API sometimes returns
  # `"back"` for back faces). Treat as a vertical full-image hash — back faces
  # are almost always portrait full-art.
  def detect(_image_binary, _meta) do
    %{x: 0.0, y: 0.0, w: 1.0, h: 1.0}
  end

  defp art_region("full-art"), do: %{x: 0.0, y: 0.0, w: 1.0, h: 1.0}
  # `extended-art` (and anything else) uses the regular art region. The
  # in-browser scanner always crops the regular region (it doesn't know
  # `art_type`), so a special extended-art crop here would never line up with
  # the captured `art` hash anyway.
  defp art_region(_), do: @regular
end
