defmodule TabletopWeb.LayoutsTest do
  @moduledoc """
  `sentry_browser_dsn/0` is rendered into the HTML of every page, so a mistake
  here is published rather than logged.
  """
  # Not async: the `sentry_browser_dsn/0` cases mutate application env.
  use ExUnit.Case, async: false

  alias TabletopWeb.Layouts

  defp put_frontend_dsn(dsn) do
    previous = Application.get_env(:tabletop, :sentry_frontend_dsn)
    Application.put_env(:tabletop, :sentry_frontend_dsn, dsn)

    on_exit(fn ->
      if previous do
        Application.put_env(:tabletop, :sentry_frontend_dsn, previous)
      else
        Application.delete_env(:tabletop, :sentry_frontend_dsn)
      end
    end)
  end

  describe "public_dsn/1" do
    test "returns nil when Sentry is not configured" do
      assert Layouts.public_dsn(nil) == nil
    end

    test "passes a modern DSN through unchanged" do
      dsn = "https://abc123@o456.ingest.sentry.io/789"

      assert Layouts.public_dsn(dsn) == dsn
    end

    test "strips the secret from a legacy DSN rather than publishing it" do
      # Pre-2016 format: https://{public}:{secret}@{host}/{project}. Sentry's own
      # parser still accepts it, and `Sentry.get_dsn/0` would return it verbatim.
      result = Layouts.public_dsn("https://public123:supersecret@o456.ingest.sentry.io/789")

      refute result =~ "supersecret"
      assert result == "https://public123@o456.ingest.sentry.io/789"
    end

    test "keeps the public key, so the SDK can still authenticate" do
      assert Layouts.public_dsn("https://onlypublic@o1.ingest.sentry.io/2") =~ "onlypublic"
    end

    test "returns nil for a URL carrying no key at all" do
      assert Layouts.public_dsn("https://o456.ingest.sentry.io/789") == nil
    end
  end

  describe "sentry_browser_dsn/0" do
    test "is nil in test, where no DSN is configured" do
      # Guards the whole design: no DSN means the client SDK never initialises,
      # so dev and test stay silent without a separate opt-out.
      assert Layouts.sentry_browser_dsn() == nil
    end

    test "reads the frontend DSN, and sanitises it on the way out" do
      put_frontend_dsn("https://front123:leaked@o1.ingest.sentry.io/2")

      result = Layouts.sentry_browser_dsn()

      assert result == "https://front123@o1.ingest.sentry.io/2"
      refute result =~ "leaked"
    end

    test "does not fall back to the server's DSN when the frontend one is unset" do
      # The two projects are deliberately separate. Falling back would quietly
      # post browser noise into the backend project — the exact mixing this
      # split exists to prevent.
      put_frontend_dsn(nil)

      assert Layouts.sentry_browser_dsn() == nil
    end
  end
end
