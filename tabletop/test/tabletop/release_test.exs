defmodule Tabletop.ReleaseTest do
  use ExUnit.Case, async: true

  describe "import_cards/1 option validation" do
    # These options are typed by hand into a production shell, so an unknown key
    # has to fail rather than be dropped — an ignored `replace_all` is
    # indistinguishable from one that found nothing to clear. Validation runs
    # before the app is loaded, so these cases never reach the database.
    test "rejects an unknown option" do
      assert_raise ArgumentError, ~r/unknown import option\(s\): \[:replace_al\]/, fn ->
        Tabletop.Release.import_cards(replace_al: true)
      end
    end

    test "names the supported options when it rejects one" do
      assert_raise ArgumentError, ~r/:replace_all/, fn ->
        Tabletop.Release.import_cards(replace_everything: true)
      end
    end

    test "rejects a non-keyword argument" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
        Tabletop.Release.import_cards(%{replace_all: true})
      end
    end
  end
end
