defmodule TabletopWeb.CardLookup do
  @moduledoc """
  Shared card lookup behaviour for LiveViews that support click-to-identify cards.

  Injects `handle_event` clauses for `open_card`, `close_card`, `switch_pitch`,
  `switch_match`, and `search_card`, plus private helpers.

  The host LiveView must initialise `open_cards: []` in its mount.

  ## `open_card` shape

  Each entry in `socket.assigns.open_cards` looks like:

      %{
        id: "<unique>",
        x: integer, y: integer,
        card: %Tabletop.Cards.Card{},        # gameplay identity (name, pitch, normalized_name, tokens)
        card_print: %Tabletop.Cards.CardPrint{},  # printing (image_url, set_code, hashes)
        pitch_variants: [%Card{} preloaded with canonical print],
        alternate_matches: [%{card: %Card{}, card_print: %CardPrint{}}, ...],
        debug: %{...}
      }

  Usage:

      use TabletopWeb.CardLookup
  """

  defmacro __using__(_opts) do
    quote do
      alias Tabletop.Cards
      alias Tabletop.Cards.{Card, CardPrint}

      def handle_event(
            "open_card",
            %{"ocr_candidates" => candidates, "x" => x, "y" => y} = params,
            socket
          ) do
        phashes = parse_phashes(params)

        detected_pitch =
          case Map.get(params, "detected_pitch") do
            p when p in [1, 2, 3] -> p
            _ -> nil
          end

        # pHash lookup first, fall back to OCR.
        phash_matches =
          if has_phash?(phashes), do: Cards.find_by_p_hash_similarity(phashes), else: []

        possible_pairs =
          if phash_matches != [] do
            phash_matches |> Enum.map(&pair_from_print/1) |> dedupe_by_card()
          else
            ocr_match_pairs(candidates)
          end

        # Sort pitch-matched cards to front
        possible_pairs =
          if detected_pitch do
            {matching, rest} =
              Enum.split_with(possible_pairs, &(&1.card.pitch == detected_pitch))

            matching ++ rest
          else
            possible_pairs
          end

        match_method =
          cond do
            has_phash?(phashes) and phash_matches != [] -> "phash"
            candidates != [] and possible_pairs != [] -> "ocr"
            true -> "none"
          end

        max_results = if match_method in ["phash", "ocr"], do: 3, else: 5
        possible_pairs = Enum.take(possible_pairs, max_results)

        debug_info = %{
          ocr_candidates: candidates,
          phashes: phashes,
          detected_pitch: detected_pitch,
          match_method: match_method
        }

        case build_open_card(possible_pairs, x, y, detected_pitch, debug_info) do
          nil ->
            {:noreply, socket}

          new_card ->
            {:noreply, assign(socket, :open_cards, socket.assigns.open_cards ++ [new_card])}
        end
      end

      # Search from within an existing popout — replaces that popout's card in place
      def handle_event("search_card", %{"query" => query, "_id" => id}, socket) do
        case String.trim(query) do
          "" ->
            {:noreply, socket}

          trimmed ->
            existing = Enum.find(socket.assigns.open_cards, &(&1.id == id))
            x = if existing, do: existing.x, else: 20
            y = if existing, do: existing.y, else: 20

            search_debug = %{
              ocr_candidates: [%{"text" => trimmed, "confidence" => nil}],
              phashes: %{},
              match_method: "search"
            }

            case build_open_card(ocr_match_pairs([%{"text" => trimmed}]), x, y, nil, search_debug) do
              nil ->
                {:noreply, socket}

              new_card ->
                cards =
                  if existing do
                    Enum.map(socket.assigns.open_cards, fn c ->
                      if c.id == id, do: %{new_card | id: id}, else: c
                    end)
                  else
                    socket.assigns.open_cards ++ [new_card]
                  end

                {:noreply, assign(socket, :open_cards, cards)}
            end
        end
      end

      # Search from the sidebar — opens a new popout
      def handle_event("search_card", %{"query" => query}, socket) do
        handle_event("search_card", %{"query" => query, "_id" => "__new__"}, socket)
      end

      def handle_event("close_card", %{"id" => id}, socket) do
        cards = Enum.reject(socket.assigns.open_cards, &(&1.id == id))
        {:noreply, assign(socket, :open_cards, cards)}
      end

      def handle_event("switch_pitch", %{"id" => id, "pitch" => pitch}, socket) do
        pitch = if is_binary(pitch), do: String.to_integer(pitch), else: pitch

        cards =
          Enum.map(socket.assigns.open_cards, fn open_card ->
            if open_card.id == id do
              case Enum.find(open_card.pitch_variants, &(&1.pitch == pitch)) do
                nil ->
                  open_card

                variant ->
                  %{
                    open_card
                    | card: variant,
                      card_print: Card.canonical_print(variant, open_card.card_print.set_code)
                  }
              end
            else
              open_card
            end
          end)

        {:noreply, assign(socket, :open_cards, cards)}
      end

      def handle_event("switch_match", %{"card_id" => _id, "normalized_name" => ""}, socket) do
        {:noreply, socket}
      end

      def handle_event("switch_match", %{"card_id" => id, "normalized_name" => name}, socket) do
        cards =
          Enum.map(socket.assigns.open_cards, fn open_card ->
            if open_card.id == id do
              case Enum.find(open_card.alternate_matches, &(&1.card.normalized_name == name)) do
                nil ->
                  open_card

                new_pair ->
                  # Rotate old card+print back into alternates
                  old_alt = %{card: open_card.card, card_print: open_card.card_print}

                  new_alternates =
                    [
                      old_alt
                      | Enum.reject(
                          open_card.alternate_matches,
                          &(&1.card.normalized_name == name)
                        )
                    ]
                    |> Enum.uniq_by(& &1.card.normalized_name)

                  new_pitch_variants =
                    Cards.find_pitch_variants(new_pair.card, new_pair.card_print.set_code)

                  selected_card =
                    if new_pitch_variants != [],
                      do: Enum.find(new_pitch_variants, new_pair.card, &(&1.pitch == 1)),
                      else: new_pair.card

                  selected_print =
                    Card.canonical_print(selected_card, new_pair.card_print.set_code) ||
                      new_pair.card_print

                  %{
                    open_card
                    | card: selected_card,
                      card_print: selected_print,
                      pitch_variants: new_pitch_variants,
                      alternate_matches: new_alternates
                  }
              end
            else
              open_card
            end
          end)

        {:noreply, assign(socket, :open_cards, cards)}
      end

      # --- helpers ---

      defp parse_phashes(params) do
        case Map.get(params, "phashes") do
          list when is_list(list) ->
            list
            |> Enum.reduce(%{}, fn entry, acc ->
              with kind when is_binary(kind) <- entry["kind"],
                   raw when is_binary(raw) <- entry["value"],
                   {int, ""} <- Integer.parse(raw),
                   atom_kind when atom_kind in [:art, :art_flipped, :art_left, :art_right, :full] <-
                     safe_kind_atom(kind) do
                Map.put(acc, atom_kind, int)
              else
                _ -> acc
              end
            end)

          _ ->
            %{}
        end
      end

      defp safe_kind_atom("art"), do: :art
      defp safe_kind_atom("art_flipped"), do: :art_flipped
      defp safe_kind_atom("art_left"), do: :art_left
      defp safe_kind_atom("art_right"), do: :art_right
      defp safe_kind_atom("full"), do: :full
      defp safe_kind_atom(_), do: nil

      defp has_phash?(phashes), do: phashes != %{} and Enum.any?(phashes, fn {_k, v} -> v end)

      # CardPrint match → {card, card_print} pair
      defp pair_from_print(%CardPrint{} = cp), do: %{card: cp.card, card_print: cp}

      # Card match (from fuzzy) → pair with canonical print
      defp pair_from_card(%Card{} = card),
        do: %{card: card, card_print: Card.canonical_print(card)}

      # Multiple prints of the same logical card → keep the first.
      defp dedupe_by_card(pairs), do: Enum.uniq_by(pairs, & &1.card.id)

      defp ocr_match_pairs(candidates) when is_list(candidates) do
        sorted = Enum.sort_by(candidates, &Map.get(&1, "confidence", 0), :desc)

        Enum.reduce_while(sorted, [], fn %{"text" => text}, _acc ->
          results = Cards.fuzzy_match_name(text)

          if results != [] do
            {:halt, Enum.map(results, &pair_from_card/1)}
          else
            {:cont, []}
          end
        end)
      end

      defp ocr_match_pairs(_), do: []

      defp build_open_card([], _x, _y, _detected_pitch, _debug_info), do: nil

      defp build_open_card(possible_pairs, x, y, detected_pitch, debug_info) do
        first = List.first(possible_pairs)

        pitch_variants =
          Cards.find_pitch_variants(first.card, first.card_print && first.card_print.set_code)

        selected_card =
          cond do
            pitch_variants == [] ->
              first.card

            detected_pitch ->
              Enum.find(pitch_variants, first.card, &(&1.pitch == detected_pitch))

            true ->
              Enum.find(pitch_variants, first.card, &(&1.pitch == 1))
          end

        selected_print =
          Card.canonical_print(selected_card, first.card_print && first.card_print.set_code) ||
            first.card_print

        alternates =
          possible_pairs
          |> Enum.reject(&(&1.card.normalized_name == first.card.normalized_name))
          |> Enum.uniq_by(& &1.card.normalized_name)

        %{
          id: System.unique_integer([:positive]) |> Integer.to_string(),
          x: x,
          y: y,
          card: selected_card,
          card_print: selected_print,
          pitch_variants: pitch_variants,
          alternate_matches: alternates,
          debug: debug_info
        }
      end
    end
  end
end
