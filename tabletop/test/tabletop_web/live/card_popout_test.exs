defmodule TabletopWeb.CardPopoutTest do
  @moduledoc """
  Covers the `TabletopWeb.CardLookup` popout via `/camera-setup`, the simplest
  LiveView that `use`s it (anonymous-friendly, no game session required).
  """
  use TabletopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletop.Cards.{Card, CardPrint}
  alias Tabletop.Repo

  # Two distinct cards whose prints hash identically, so one scan matches both
  # and the popout offers a match dropdown.
  @phash 0x0F0F_0F0F_0F0F_0F0F

  setup do
    %{
      first: card_with_print("Scar for a Scar", "scar-for-a-scar"),
      second: card_with_print("Scar Tissue", "scar-tissue")
    }
  end

  defp card_with_print(name, external_id) do
    card =
      %Card{}
      |> Card.changeset(%{name: name, external_card_id: external_id})
      |> Repo.insert!()

    %CardPrint{}
    |> CardPrint.changeset(%{
      card_id: card.id,
      face_id: "#{external_id}-face",
      set_code: "TST",
      art_type: "regular",
      orientation: "vertical",
      is_canonical: true,
      image_url: "https://example.test/#{external_id}.png",
      image_phash: @phash,
      image_phash_full: @phash
    })
    |> Repo.insert!()

    Repo.reload!(card)
  end

  defp open_popout(conn) do
    {:ok, live_view, _html} = live(conn, ~p"/camera-setup")

    render_hook(live_view, "open_card", %{
      "x" => 10,
      "y" => 10,
      "phashes" => [%{"kind" => "art", "value" => Integer.to_string(@phash)}]
    })

    live_view
  end

  describe "match dropdown" do
    test "lists every match, with the displayed one selected", %{conn: conn} do
      live_view = open_popout(conn)

      assert has_element?(live_view, ~s(option[value="SCAR FOR A SCAR"][selected]))
      assert has_element?(live_view, ~s(option[value="SCAR TISSUE"]))
    end

    # The select is focused when its change event fires, and LiveView carries a
    # focused select's value across the patch (`isChangedSelect/2`). If the
    # picked option were dropped from the list — as it was when the current card
    # rendered as a magic `value=""` entry — the select would be left pointing at
    # a value with no matching option and would render blank.
    test "keeps the picked option in the list after switching", %{conn: conn} do
      live_view = open_popout(conn)

      html =
        live_view
        |> element("form[phx-change='switch_match']")
        |> render_change(%{"normalized_name" => "SCAR TISSUE"})

      assert html =~ "Scar Tissue"
      assert has_element?(live_view, ~s(option[value="SCAR TISSUE"][selected]))
      assert has_element?(live_view, ~s(option[value="SCAR FOR A SCAR"]))
      refute has_element?(live_view, ~s(option[value=""]))
    end

    test "switching back to the original match still works", %{conn: conn} do
      live_view = open_popout(conn)
      form = element(live_view, "form[phx-change='switch_match']")

      render_change(form, %{"normalized_name" => "SCAR TISSUE"})
      html = render_change(form, %{"normalized_name" => "SCAR FOR A SCAR"})

      assert html =~ "Scar for a Scar"
      assert has_element?(live_view, ~s(option[value="SCAR FOR A SCAR"][selected]))
    end

    test "an unknown name leaves the popout alone", %{conn: conn} do
      live_view = open_popout(conn)

      html =
        live_view
        |> element("form[phx-change='switch_match']")
        |> render_change(%{"normalized_name" => "NO SUCH CARD"})

      assert html =~ "Scar for a Scar"
      assert has_element?(live_view, ~s(option[value="SCAR FOR A SCAR"][selected]))
    end
  end

  test "no dropdown is rendered when only one card matches", %{conn: conn} do
    Repo.delete_all(CardPrint)
    card_with_print("Scar for a Scar", "solo-match")

    live_view = open_popout(conn)

    assert has_element?(live_view, "[id^='card-popout-']")
    refute has_element?(live_view, "form[phx-change='switch_match']")
  end
end
