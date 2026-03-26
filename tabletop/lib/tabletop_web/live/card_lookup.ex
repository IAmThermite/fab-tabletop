defmodule TabletopWeb.CardLookup do
  @moduledoc """
  Shared card lookup behaviour for LiveViews that support click-to-identify cards.

  Injects `handle_event` clauses for `open_card`, `close_card`, `switch_pitch`,
  and `search_card`, plus private helpers.

  The host LiveView must initialise `open_cards: []` in its mount.

  Usage:

      use TabletopWeb.CardLookup
  """

  defmacro __using__(_opts) do
    quote do
      def handle_event(
            "open_card",
            %{"ocr_candidates" => candidates, "x" => x, "y" => y} = params,
            socket
          ) do
        phash =
          case Map.get(params, "phash") do
            s when is_binary(s) -> String.to_integer(s)
            _ -> nil
          end

        phash_flipped =
          case Map.get(params, "phash_flipped") do
            s when is_binary(s) -> String.to_integer(s)
            _ -> nil
          end

        detected_pitch =
          case Map.get(params, "detected_pitch") do
            p when p in [1, 2, 3] -> p
            _ -> nil
          end

        possible_cards =
          cond do
            phash && phash_flipped ->
              Tabletop.Cards.find_by_p_hash_similarity_dual(phash, phash_flipped)

            phash ->
              Tabletop.Cards.find_by_p_hash_similarity(phash)

            true ->
              []
          end

        possible_cards =
          if possible_cards == [] && candidates != [] do
            sorted = Enum.sort_by(candidates, & &1["confidence"], :desc)

            Enum.reduce_while(sorted, [], fn %{"text" => text}, _acc ->
              results = Tabletop.Cards.fuzzy_match_name(text)
              if results != [], do: {:halt, results}, else: {:cont, []}
            end)
          else
            possible_cards
          end

        # Sort pitch-matched cards to front
        possible_cards =
          if detected_pitch do
            {matching, rest} = Enum.split_with(possible_cards, &(&1.pitch == detected_pitch))
            matching ++ rest
          else
            possible_cards
          end

        match_method =
          cond do
            phash && possible_cards != [] -> "phash"
            candidates != [] && possible_cards != [] -> "ocr"
            true -> "none"
          end

        max_results = if match_method in ["phash", "ocr"], do: 3, else: 5
        possible_cards = Enum.take(possible_cards, max_results)

        debug_info = %{
          ocr_candidates: candidates,
          phash: phash,
          phash_flipped: phash_flipped,
          detected_pitch: detected_pitch,
          match_method: match_method
        }

        case build_open_card(possible_cards, x, y, detected_pitch, debug_info) do
          nil -> {:noreply, socket}
          new_card -> {:noreply, assign(socket, :open_cards, socket.assigns.open_cards ++ [new_card])}
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

            search_debug = %{ocr_candidates: [%{"text" => trimmed, "confidence" => nil}], phash: nil, match_method: "search"}

            case build_open_card(Tabletop.Cards.fuzzy_match_name(trimmed), x, y, nil, search_debug) do
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
                nil -> open_card
                variant -> %{open_card | card: variant}
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
              case Enum.find(open_card.alternate_matches, &(&1.normalized_name == name)) do
                nil ->
                  open_card

                new_card ->
                  # Rotate old card back into alternates
                  old_base =
                    Enum.find(open_card.pitch_variants, open_card.card, &(&1.pitch == 1))

                  new_alternates =
                    [old_base | Enum.reject(open_card.alternate_matches, &(&1.normalized_name == name))]
                    |> Enum.uniq_by(& &1.normalized_name)

                  new_pitch_variants =
                    Tabletop.Cards.find_pitch_variants(new_card, new_card.set_code)

                  new_selected =
                    if new_pitch_variants != [],
                      do: Enum.find(new_pitch_variants, new_card, &(&1.pitch == 1)),
                      else: new_card

                  %{open_card |
                    card: new_selected,
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

      defp build_open_card([], _x, _y, _detected_pitch, _debug_info), do: nil

      defp build_open_card(possible_cards, x, y, detected_pitch, debug_info) do
        card = List.first(possible_cards)
        pitch_variants = Tabletop.Cards.find_pitch_variants(card, card.set_code)

        selected_card =
          cond do
            pitch_variants == [] ->
              card

            detected_pitch ->
              Enum.find(pitch_variants, card, &(&1.pitch == detected_pitch))

            true ->
              Enum.find(pitch_variants, card, &(&1.pitch == 1))
          end

        alternates =
          possible_cards
          |> Enum.reject(&(&1.normalized_name == card.normalized_name))
          |> Enum.uniq_by(& &1.normalized_name)

        %{
          id: System.unique_integer([:positive]) |> Integer.to_string(),
          x: x,
          y: y,
          card: selected_card,
          pitch_variants: pitch_variants,
          alternate_matches: alternates,
          debug: debug_info
        }
      end
    end
  end
end
