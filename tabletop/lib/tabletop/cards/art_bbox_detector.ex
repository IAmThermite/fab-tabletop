defmodule Tabletop.Cards.ArtBboxDetector do
  @moduledoc """
  Computes the art-region bounding box for a printed FaB card image.

  Returns bounding boxes as ratios (each component in 0..1) so they're
  resolution-independent.

  - Vertical card → `%{x, y, w, h}`.
  - Horizontal card → `%{halves: [%{x, y, w, h}, %{x, y, w, h}]}`. The
    cardvault `_large` images for horizontal cards are stored in **portrait**
    orientation (the played-landscape card rotated 90° to fit), so the halves
    are top/bottom of the file rather than left/right.

  Both shapes are plain maps so they fit Ecto's `:map` field type.

  The current implementation uses fixed ratios per (`orientation`, `art_type`).
  An earlier OpenCV/evision contour-based attempt didn't reliably outperform
  fixed ratios on the canonical sample (Arakni / Everbloom / Great Library /
  Chum), so we settled on something simple and predictable. The evision
  dependency is kept so a future iteration can revisit per-image detection.
  """

  alias Evision, as: Cv
  alias Evision.Constant

  @doc """
  Compute art bbox(es) for a card image.

    * `image_binary` – raw bytes of the printed card image.
    * `meta` – at least `:orientation` (`"vertical"` | `"horizontal"`) and
      `:art_type` (`"regular"` | `"extended-art"` | `"full-art"`).

  Returns `%{x, y, w, h}` for vertical, or `%{halves: [%{...}, %{...}]}` for
  horizontal. Both shapes are plain maps.
  """
  @spec detect(binary(), map()) :: map()
  def detect(_image_binary, %{orientation: "vertical", art_type: art_type}) do
    case art_type do
      "full-art" -> %{x: 0.0, y: 0.0, w: 1.0, h: 1.0}
      "extended-art" -> %{x: 0.04, y: 0.07, w: 0.92, h: 0.55}
      _ -> %{x: 0.10, y: 0.16, w: 0.80, h: 0.42}
    end
  end

  def detect(image_binary, %{orientation: "horizontal"}) when is_binary(image_binary) do
    # Bisect along the long axis. Horizontal cards from the cardvault API are
    # almost always stored portrait, but inspect the image to be sure.
    halves =
      case image_dimensions(image_binary) do
        {:ok, w, h} when h >= w ->
          # Portrait file → halves are top/bottom.
          [
            %{x: 0.0, y: 0.0, w: 1.0, h: 0.5},
            %{x: 0.0, y: 0.5, w: 1.0, h: 0.5}
          ]

        {:ok, _w, _h} ->
          # Landscape file → halves are left/right.
          [
            %{x: 0.0, y: 0.0, w: 0.5, h: 1.0},
            %{x: 0.5, y: 0.0, w: 0.5, h: 1.0}
          ]

        :error ->
          # Best guess: most are portrait.
          [
            %{x: 0.0, y: 0.0, w: 1.0, h: 0.5},
            %{x: 0.0, y: 0.5, w: 1.0, h: 0.5}
          ]
      end

    %{halves: halves}
  end

  # Fallback for unexpected orientations (e.g. the API sometimes returns
  # `"back"` for back faces). Treat as a vertical full-image hash — back faces
  # are almost always portrait full-art.
  def detect(_image_binary, _meta) do
    %{x: 0.0, y: 0.0, w: 1.0, h: 1.0}
  end

  defp image_dimensions(bin) do
    case Cv.imdecode(bin, Constant.cv_IMREAD_COLOR()) do
      {:error, _} ->
        :error

      mat ->
        case Cv.Mat.shape(mat) do
          {h, w} -> {:ok, w, h}
          {h, w, _channels} -> {:ok, w, h}
          [h, w | _] -> {:ok, w, h}
          _ -> :error
        end
    end
  end
end
