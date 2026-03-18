defmodule TabletopWeb.CardLookup do
  @moduledoc """
  Shared card lookup behaviour for LiveViews that support click-to-identify cards.

  Injects `handle_event` clauses for `open_card` and `close_card`, plus the
  `assign_open_card/4` private helper.

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

        assign_open_card(socket, possible_cards, x, y)
      end

      def handle_event("close_card", %{"id" => id}, socket) do
        cards = Enum.reject(socket.assigns.open_cards, &(&1.id == id))
        {:noreply, assign(socket, :open_cards, cards)}
      end

      defp assign_open_card(socket, [], _x, _y), do: {:noreply, socket}

      defp assign_open_card(socket, possible_cards, x, y) do
        card = List.first(possible_cards)

        new_card = %{
          id: System.unique_integer([:positive]) |> Integer.to_string(),
          x: x,
          y: y,
          card: card
        }

        {:noreply, assign(socket, :open_cards, socket.assigns.open_cards ++ [new_card])}
      end
    end
  end
end
