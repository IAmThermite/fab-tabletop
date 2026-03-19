defmodule TabletopWeb.CardLookup do
  @moduledoc """
  Shared card lookup behaviour for LiveViews that support click-to-identify cards.

  Injects `handle_event` clauses for `open_card`, `close_card`, and `switch_pitch`,
  plus the `assign_open_card/5` private helper.

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

        detected_pitch =
          case Map.get(params, "detected_pitch") do
            p when p in [1, 2, 3] -> p
            _ -> nil
          end

        possible_cards =
          if phash do
            Tabletop.Cards.find_by_p_hash_similarity(phash)
          else
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

        assign_open_card(socket, possible_cards, x, y, detected_pitch)
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

      defp assign_open_card(socket, [], _x, _y, _detected_pitch), do: {:noreply, socket}

      defp assign_open_card(socket, possible_cards, x, y, detected_pitch) do
        card = List.first(possible_cards)
        pitch_variants = Tabletop.Cards.find_pitch_variants(card)

        # Select the displayed card: use detected pitch, default to red (pitch 1), or the match
        selected_card =
          cond do
            pitch_variants == [] ->
              card

            detected_pitch ->
              Enum.find(pitch_variants, card, &(&1.pitch == detected_pitch))

            true ->
              # Default to red (pitch 1) if available
              Enum.find(pitch_variants, card, &(&1.pitch == 1))
          end

        new_card = %{
          id: System.unique_integer([:positive]) |> Integer.to_string(),
          x: x,
          y: y,
          card: selected_card,
          pitch_variants: pitch_variants
        }

        {:noreply, assign(socket, :open_cards, socket.assigns.open_cards ++ [new_card])}
      end
    end
  end
end
