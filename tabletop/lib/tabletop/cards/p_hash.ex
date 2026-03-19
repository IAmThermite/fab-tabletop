defmodule Tabletop.Cards.PHash do
  @moduledoc """
  Perceptual hash (pHash) for card art images.

  Matches the DCT-based algorithm in `assets/js/card_scanner/p_hash.js`:
  1. Crop to the art region of the card
  2. Resize to 32x32 grayscale
  3. 2D DCT
  4. Take top-left 8x8 low-frequency block (excluding DC)
  5. Threshold against median -> 64-bit hash

  Uses ImageMagick `convert` for image decoding/cropping/resizing,
  which supports webp, png, jpg, gif, etc.
  """

  require Logger

  @hash_size 8
  @dct_size 32

  # Art region ratios — must match scanner_worker.js
  @art_y_ratio 0.12
  @art_h_ratio 0.48
  @art_x_inset 0.09

  # Precompute cosine table: cos((2j+1) * i * pi / (2*N))
  @cos_table (for i <- 0..(@dct_size - 1),
                  j <- 0..(@dct_size - 1),
                  into: %{} do
                {{i, j}, :math.cos((2 * j + 1) * i * :math.pi() / (2 * @dct_size))}
              end)

  @doc """
  Downloads the image at `image_url`, crops the art region, and computes
  a 64-bit integer pHash. Returns `nil` on failure.
  """
  @spec compute(String.t(), keyword()) :: integer() | nil
  def compute(image_url, req_options \\ []) do
    with {:ok, body} <- download(image_url, req_options),
         {:ok, gray} <- decode_art_region(body) do
      gray |> dct_2d() |> hash_from_dct()
    else
      _ -> nil
    end
  end

  @doc """
  Computes pHash from a local file path. Returns `nil` on failure.
  """
  @spec compute_from_file(String.t()) :: integer() | nil
  def compute_from_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, gray} <- decode_art_region(body) do
      gray |> dct_2d() |> hash_from_dct()
    else
      _ -> nil
    end
  end

  @doc """
  Crops the art region from an image binary and writes it to `output_path` as PNG.
  Useful for visually verifying the crop region.
  """
  @spec save_art_region(binary(), String.t()) :: :ok | :error
  def save_art_region(image_binary, output_path) do
    with_tempfile(image_binary, fn tmp_path ->
      case image_dimensions(tmp_path) do
        {:ok, w, h} ->
          geometry = art_geometry(w, h)

          case System.cmd(
                 "convert",
                 ["#{tmp_path}[0]", "-crop", geometry, "+repage", output_path],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              :ok

            {err, _} ->
              Logger.warning("PHash: convert crop failed: #{err}")
              :error
          end

        :error ->
          :error
      end
    end)
  end

  @doc """
  Computes hamming distance between two integer pHashes (0-64).
  """
  @spec hamming_distance(integer(), integer()) :: non_neg_integer()
  def hamming_distance(a, b) when is_integer(a) and is_integer(b) do
    Bitwise.bxor(a, b) |> popcount(0)
  end

  def hamming_distance(_, _), do: 64

  defp popcount(0, acc), do: acc
  defp popcount(n, acc), do: popcount(Bitwise.band(n, n - 1), acc + 1)

  # --- Image download ---

  defp download(url, req_options) do
    case Req.get(url, [receive_timeout: 15_000, retry: :transient, max_retries: 2] ++ req_options) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("PHash: HTTP #{status} fetching #{url}")
        :error

      {:error, reason} ->
        Logger.warning("PHash: failed to fetch #{url}: #{inspect(reason)}")
        :error
    end
  end

  # --- ImageMagick pipeline: crop art region -> resize 32x32 -> grayscale -> raw bytes ---

  defp decode_art_region(image_binary) do
    with_tempfile(image_binary, fn tmp_path ->
      with {:ok, w, h} <- image_dimensions(tmp_path) do
        geometry = art_geometry(w, h)
        n = @dct_size

        # Output raw RGB (not grayscale) so we can apply the same
        # luminance formula as the JS: 0.299R + 0.587G + 0.114B
        case System.cmd(
               "convert",
               [
                 "#{tmp_path}[0]",
                 "-crop",
                 geometry,
                 "+repage",
                 "-resize",
                 "#{n}x#{n}!",
                 "-depth",
                 "8",
                 "rgb:-"
               ],
               stderr_to_stdout: true
             ) do
          {raw, 0} when byte_size(raw) == n * n * 3 ->
            gray =
              for <<r, g, b <- raw>> do
                0.299 * r + 0.587 * g + 0.114 * b
              end

            {:ok, gray}

          {err, _} ->
            Logger.warning("PHash: convert failed: #{String.slice(err, 0, 200)}")
            :error
        end
      end
    end)
  end

  defp image_dimensions(path) do
    case System.cmd("identify", ["-format", "%w %h", "#{path}[0]"], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(String.trim(output)) do
          [w_str, h_str] ->
            {:ok, String.to_integer(w_str), String.to_integer(h_str)}

          _ ->
            Logger.warning("PHash: unexpected identify output: #{output}")
            :error
        end

      {err, _} ->
        Logger.warning("PHash: identify failed: #{err}")
        :error
    end
  end

  defp art_geometry(w, h) do
    x = round(w * @art_x_inset)
    y = round(h * @art_y_ratio)
    crop_w = round(w * (1 - 2 * @art_x_inset))
    crop_h = round(h * @art_h_ratio)
    "#{crop_w}x#{crop_h}+#{x}+#{y}"
  end

  defp with_tempfile(binary, fun) do
    tmp_path = Path.join(System.tmp_dir!(), "phash_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(tmp_path, binary)
      fun.(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

  # --- 2D DCT ---

  defp dct_2d(gray) do
    n = @dct_size
    gray_arr = :array.from_list(gray)

    row_dct = :array.new(n * n, default: 0.0)

    row_dct =
      Enum.reduce(0..(n - 1), row_dct, fn y, acc ->
        Enum.reduce(0..(n - 1), acc, fn u, acc2 ->
          sum =
            Enum.reduce(0..(n - 1), 0.0, fn x, s ->
              s + :array.get(y * n + x, gray_arr) * @cos_table[{u, x}]
            end)

          :array.set(y * n + u, sum, acc2)
        end)
      end)

    for v <- 0..(n - 1), u <- 0..(n - 1), into: %{} do
      sum =
        Enum.reduce(0..(n - 1), 0.0, fn y, acc ->
          acc + :array.get(y * n + u, row_dct) * @cos_table[{v, y}]
        end)

      {{v, u}, sum}
    end
  end

  # --- Hash from DCT coefficients ---

  defp hash_from_dct(dct) do
    coeffs =
      for y <- 0..(@hash_size - 1),
          x <- 0..(@hash_size - 1),
          not (x == 0 and y == 0) do
        dct[{y, x}]
      end

    sorted = Enum.sort(coeffs)
    len = length(sorted)
    mid = div(len, 2)

    median =
      if rem(len, 2) == 0 do
        (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
      else
        Enum.at(sorted, mid)
      end

    bits = [0 | Enum.map(coeffs, fn c -> if c > median, do: 1, else: 0 end)]

    Enum.reduce(bits, 0, fn bit, acc -> acc * 2 + bit end)
  end
end
