# Run with: mix run scripts/smoke_detector.exs
#
# Downloads a handful of example cards from cardvault, runs the art-bbox
# detector, and saves the cropped art regions to /tmp/phash_smoke/ for visual
# verification.

require Logger

alias Tabletop.Cards.ArtBboxDetector

out_dir = "/tmp/phash_smoke"
File.mkdir_p!(out_dir)

cards = [
  %{
    label: "sink_below",
    url: "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/1HP409.webp",
    orientation: "vertical",
    art_type: "regular"
  }
]

crop_with_imagemagick = fn input_path, %{x: x, y: y, w: w, h: h}, output_path ->
  case System.cmd(
         "identify",
         ["-format", "%w %h", "#{input_path}[0]"],
         stderr_to_stdout: true
       ) do
    {info, 0} ->
      [iw_str, ih_str] = info |> String.trim() |> String.split()
      iw = String.to_integer(iw_str)
      ih = String.to_integer(ih_str)
      cx = round(iw * x)
      cy = round(ih * y)
      cw = round(iw * w)
      ch = round(ih * h)
      geometry = "#{cw}x#{ch}+#{cx}+#{cy}"

      {_, 0} =
        System.cmd(
          "convert",
          ["#{input_path}[0]", "-crop", geometry, "+repage", output_path],
          stderr_to_stdout: true
        )

      :ok

    other ->
      {:error, other}
  end
end

Enum.each(cards, fn %{label: label, url: url, orientation: orient, art_type: art_type} ->
  IO.puts("\n--- #{label} (#{orient}, #{art_type}) ---")

  with {:ok, %{status: 200, body: body}} when is_binary(body) <-
         Req.get(url, receive_timeout: 30_000, retry: :transient, max_retries: 2) do
    raw_path = Path.join(out_dir, "#{label}_raw.webp")
    File.write!(raw_path, body)

    %{x: _, y: _, w: _, h: _} = single =
      ArtBboxDetector.detect(body, %{orientation: orient, art_type: art_type})

    IO.inspect(single, label: "  bbox")
    out = Path.join(out_dir, "#{label}_crop.png")
    crop_with_imagemagick.(raw_path, single, out)
    IO.puts("  saved → #{out}")
  else
    err -> IO.puts("  fetch failed: #{inspect(err)}")
  end
end)

IO.puts("\nDone. Images in #{out_dir}")
