defmodule TabletopWeb.Plugs.SecurityHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias TabletopWeb.Plugs.SecurityHeaders

  @card_source Path.expand(
                 "../../../../vendor/flesh-and-blood-cards/json/english/card.json",
                 __DIR__
               )

  defp csp do
    :get
    |> conn("/")
    |> SecurityHeaders.call([])
    |> get_resp_header("content-security-policy")
    |> List.first()
  end

  defp directive(name) do
    csp()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, name <> " "))
    |> String.split(" ")
    |> tl()
  end

  # Mirrors how a browser matches a URL against a CSP source expression: scheme +
  # host must match (`*.` wildcards a subdomain), and a source carrying a path
  # only matches URLs under that path.
  defp allowed?(url, sources) do
    %URI{scheme: scheme, host: host, path: path} = URI.parse(url)
    Enum.any?(sources, &source_matches?(&1, scheme, host, path || "/"))
  end

  defp source_matches?(source, scheme, host, path) do
    %URI{scheme: source_scheme, host: source_host, path: source_path} = URI.parse(source)

    source_scheme == scheme and host_matches?(source_host, host) and
      path_matches?(source_path, path)
  end

  defp host_matches?("*." <> domain, host), do: String.ends_with?(host, "." <> domain)
  defp host_matches?(source_host, host), do: source_host == host

  defp path_matches?(nil, _path), do: true
  defp path_matches?("", _path), do: true
  defp path_matches?("/", _path), do: true
  defp path_matches?(source_path, path), do: String.starts_with?(path, source_path)

  describe "content-security-policy" do
    test "is set alongside the other security headers" do
      conn = SecurityHeaders.call(conn(:get, "/"), [])

      assert [_csp] = get_resp_header(conn, "content-security-policy")
      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
    end

    test "script-src carries the per-request nonce exposed to the layout" do
      conn = SecurityHeaders.call(conn(:get, "/"), [])

      assert conn.assigns.csp_nonce =~ ~r/\A[\w-]+\z/
      assert csp_of(conn) =~ "'nonce-#{conn.assigns.csp_nonce}'"
    end

    test "nonce differs between requests" do
      one = SecurityHeaders.call(conn(:get, "/"), [])
      two = SecurityHeaders.call(conn(:get, "/"), [])

      refute one.assigns.csp_nonce == two.assigns.csp_nonce
    end
  end

  describe "img-src" do
    test "allows same-origin assets and canvas captures" do
      sources = directive("img-src")

      assert "'self'" in sources
      assert "data:" in sources
      assert "blob:" in sources
    end

    test "allows every card-image host the plug declares" do
      sources = directive("img-src")

      for source <- SecurityHeaders.card_image_sources() do
        assert source in sources
      end
    end

    test "allows a representative URL from each card-image host" do
      sources = directive("img-src")

      urls = [
        "https://storage.googleapis.com/fabmaster/cardfaces/ARC000.width-450.png",
        "https://storage.googleapis.com/fabmaster/media/cards/ARC000.width-450.png",
        "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/OUT234.webp",
        "https://d2wlb52bya4y8z.cloudfront.net/media/cards/WTR001.width-450.png",
        "https://dhhim4ltzu1pj.cloudfront.net/media/images/CRU001.width-450.png",
        "https://cdn.fabtcg.com/uploads/2026/card.png"
      ]

      for url <- urls do
        assert allowed?(url, sources), "img-src blocks #{url}"
      end
    end

    test "does not allow unrelated hosts" do
      sources = directive("img-src")

      refute allowed?("https://evil.example.com/tracker.png", sources)
      refute allowed?("https://storage.googleapis.com/some-other-bucket/tracker.png", sources)
      refute allowed?("https://other-bucket.s3.amazonaws.com/tracker.png", sources)
    end

    @tag :card_data
    test "allows every image URL in the vendored card data set" do
      if File.exists?(@card_source) do
        sources = directive("img-src")

        blocked =
          @card_source
          |> File.stream!()
          |> Stream.flat_map(fn line ->
            Regex.scan(~r/"image_url":\s*"([^"]+)"/, line, capture: :all_but_first)
          end)
          |> Stream.map(fn [url] -> url end)
          |> Stream.reject(&allowed?(&1, sources))
          |> Stream.map(&URI.parse/1)
          |> Stream.map(&"#{&1.scheme}://#{&1.host}#{&1.path}")
          |> Enum.uniq()
          |> Enum.take(5)

        assert blocked == [],
               "img-src blocks card images from the data set — add the host(s) to " <>
                 "SecurityHeaders.card_image_sources/0: #{inspect(blocked)}"
      else
        # The card data set is a git submodule and is not checked out everywhere
        # (CI runs `actions/checkout` without submodules).
        IO.puts("skipping: #{@card_source} not checked out")
      end
    end
  end

  defp csp_of(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()
end
