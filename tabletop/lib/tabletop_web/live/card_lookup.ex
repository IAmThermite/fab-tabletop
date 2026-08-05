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
        matches: [%{card: %Card{}, card_print: %CardPrint{}}, ...],
        debug: %{...}
      }

  `matches` holds *every* candidate the lookup returned, including the one
  currently displayed, in a fixed order — `switch_match` only moves the
  selection, never the list. Keep it that way: the `<select>` in
  `card_popouts/1` is patched while the user has it focused, and LiveView
  preserves the focused select's value across that patch
  (`isChangedSelect/2`). Drop the picked option from the list and the select
  is left pointing at a value that no longer exists, which renders blank.

  Usage:

      use TabletopWeb.CardLookup
  """

  @doc """
  Emits the card-scan telemetry event for one `open_card` attempt.

  Lives on the module rather than inside `__using__/1` so the logic is defined
  once instead of being injected into every host LiveView. `region_scale` is
  `1.0` on the scanner's first attempt and larger once it has started growing
  the capture region, so `first_try` separates clean reads from ones that only
  landed after a retry — a hit rate that depends on retries is a different
  problem from one that doesn't.
  """
  def record_card_scan(phashes, possible_pairs, started_at, region_scale) do
    duration = System.monotonic_time() - started_at
    first_try? = region_scale <= 1.0

    case possible_pairs do
      [%{card_print: card_print} | _] when not is_nil(card_print) ->
        case Tabletop.Cards.best_phash_match(phashes, card_print) do
          {arm, distance} ->
            Tabletop.Telemetry.card_scan(duration, :match, first_try?, distance, arm)

          nil ->
            # Matched via an arm we can't reconstruct (e.g. the popout swapped in
            # a pitch variant's print). Still a match — just no distance to report.
            Tabletop.Telemetry.card_scan(duration, :match, first_try?)
        end

      [_ | _] ->
        Tabletop.Telemetry.card_scan(duration, :match, first_try?)

      [] ->
        Tabletop.Telemetry.card_scan(duration, :miss, first_try?)
    end
  end

  defmacro __using__(_opts) do
    quote do
      alias Tabletop.Cards
      alias Tabletop.Cards.{Card, CardPrint}

      def handle_event("open_card", %{"x" => x, "y" => y} = params, socket) do
        phashes = parse_phashes(params)

        detected_pitch =
          case Map.get(params, "detected_pitch") do
            p when p in [1, 2, 3] -> p
            _ -> nil
          end

        # 1.0 means the scanner matched on its first try; > 1.0 means it
        # resolved via the expanded-region retry (see liveview_hook.js).
        region_scale =
          case Map.get(params, "region_scale") do
            n when is_number(n) and n >= 1.0 -> n / 1
            _ -> 1.0
          end

        # Recognition is pHash-only — no OCR. (Manual name search uses `search_card`.)
        scan_started_at = System.monotonic_time()

        possible_pairs =
          if has_phash?(phashes) do
            Cards.find_by_p_hash_similarity(phashes)
            |> Enum.map(&pair_from_print/1)
            |> dedupe_by_card()
          else
            []
          end

        TabletopWeb.CardLookup.record_card_scan(
          phashes,
          possible_pairs,
          scan_started_at,
          region_scale
        )

        # Sort pitch-matched cards to front
        possible_pairs =
          if detected_pitch do
            {matching, rest} =
              Enum.split_with(possible_pairs, &(&1.card.pitch == detected_pitch))

            matching ++ rest
          else
            possible_pairs
          end

        match_method = if possible_pairs != [], do: "phash", else: "none"

        possible_pairs = Enum.take(possible_pairs, 3)

        debug_info = %{
          phashes: phashes,
          detected_pitch: detected_pitch,
          match_method: match_method,
          region_scale: region_scale
        }

        # Always reply with whether a card matched — the client retry loop
        # (which grows the capture region on a miss) waits on this.
        case build_open_card(possible_pairs, x, y, detected_pitch, debug_info) do
          nil ->
            {:reply, %{matched: false}, socket}

          new_card ->
            reply =
              if Map.get(params, "debug_capture") == true do
                # Debug-only: lets the client hold this scan's capture against
                # the popout it just opened, for the "Save scan capture" button.
                # Reports the print the pHash query actually hit — not the
                # popout's displayed print, which may have been swapped for a
                # pitch variant or canonical printing.
                Map.put(%{matched: true}, :match, capture_match_info(possible_pairs, new_card.id))
              else
                %{matched: true}
              end

            {:reply, reply, assign(socket, :open_cards, socket.assigns.open_cards ++ [new_card])}
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
              phashes: %{},
              match_method: "search"
            }

            case build_open_card(
                   text_match_pairs([%{"text" => trimmed}]),
                   x,
                   y,
                   nil,
                   search_debug
                 ) do
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

      def handle_event("switch_match", %{"card_id" => id, "normalized_name" => name}, socket) do
        cards =
          Enum.map(socket.assigns.open_cards, fn open_card ->
            # `matches` stays put — only the selection moves. See the moduledoc.
            with true <- open_card.id == id,
                 true <- open_card.card.normalized_name != name,
                 pair when not is_nil(pair) <-
                   Enum.find(open_card.matches, &(&1.card.normalized_name == name)) do
              {selected_card, selected_print, pitch_variants} = resolve_display(pair, nil)

              %{
                open_card
                | card: selected_card,
                  card_print: selected_print,
                  pitch_variants: pitch_variants
              }
            else
              _ -> open_card
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
                   atom_kind when atom_kind in [:art, :art_flipped, :full] <-
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
      defp safe_kind_atom("full"), do: :full
      defp safe_kind_atom(_), do: nil

      defp has_phash?(phashes), do: phashes != %{} and Enum.any?(phashes, fn {_k, v} -> v end)

      # CardPrint match → {card, card_print} pair
      defp pair_from_print(%CardPrint{} = cp), do: %{card: cp.card, card_print: cp}

      # Card match (from name search) → pair with canonical print
      defp pair_from_card(%Card{} = card),
        do: %{card: card, card_print: Card.canonical_print(card)}

      # Multiple prints of the same logical card → keep the first.
      defp dedupe_by_card(pairs), do: Enum.uniq_by(pairs, & &1.card.id)

      # Manual name-search matcher (the `search_card` box). Fuzzy-matches the
      # typed text against card names via Postgres similarity + dmetaphone.
      defp text_match_pairs(candidates) when is_list(candidates) do
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

      defp text_match_pairs(_), do: []

      # Identity + stored hashes of the print the scan matched, for the debug
      # capture export. Hashes go over the wire as strings — they are 63-bit
      # and would lose precision as JS numbers.
      defp capture_match_info([%{card: card, card_print: print} | _], card_id) do
        %{
          card_id: card_id,
          face_id: print.face_id,
          card_name: card.name,
          set_code: print.set_code,
          pitch: card.pitch,
          image_phash: stringify_phash(print.image_phash),
          image_phash_full: stringify_phash(print.image_phash_full)
        }
      end

      defp capture_match_info(_, _), do: nil

      defp stringify_phash(nil), do: nil
      defp stringify_phash(value) when is_integer(value), do: Integer.to_string(value)

      defp build_open_card([], _x, _y, _detected_pitch, _debug_info), do: nil

      defp build_open_card(possible_pairs, x, y, detected_pitch, debug_info) do
        first = List.first(possible_pairs)
        {selected_card, selected_print, pitch_variants} = resolve_display(first, detected_pitch)

        %{
          id: System.unique_integer([:positive]) |> Integer.to_string(),
          x: x,
          y: y,
          card: selected_card,
          card_print: selected_print,
          pitch_variants: pitch_variants,
          matches: Enum.uniq_by(possible_pairs, & &1.card.normalized_name),
          debug: debug_info
        }
      end

      # Given a matched {card, card_print} pair, pick the card + print the
      # popout should actually show: the pitch the scanner detected when it
      # detected one, else pitch 1, with that card's canonical print biased
      # toward the matched print's set.
      defp resolve_display(pair, detected_pitch) do
        set_code = pair.card_print && pair.card_print.set_code
        pitch_variants = Cards.find_pitch_variants(pair.card, set_code)

        selected_card =
          cond do
            pitch_variants == [] -> pair.card
            detected_pitch -> Enum.find(pitch_variants, pair.card, &(&1.pitch == detected_pitch))
            true -> Enum.find(pitch_variants, pair.card, &(&1.pitch == 1))
          end

        selected_print = Card.canonical_print(selected_card, set_code) || pair.card_print

        {selected_card, selected_print, pitch_variants}
      end
    end
  end
end
