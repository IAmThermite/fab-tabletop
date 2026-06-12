defmodule TabletopWeb.GameControls do
  @moduledoc """
  Shared LiveView event handlers for the game sidebar and tiles.

  Both the live game (`TabletopWeb.GameLive.Show`) and the camera-setup preview
  (`TabletopWeb.CameraSetupLive`) render the same `GameComponents.game_sidebar`
  and `game_tiles`, so they emit the same `phx-click`/`phx-submit` events. This
  macro injects one set of `handle_event/3` clauses for all of them: each event
  is turned into a `Tabletop.Fab.GameState` action tuple and handed to the host
  LiveView's `apply_game_action/2`, which decides HOW to apply it:

    * the live game routes it through `GameSession` (authoritative, broadcast)
    * the setup preview applies it locally to its own preview state

  The action vocabulary matches `Tabletop.Fab.GameState.transform/2`. `move_tile`
  is passed through with its raw `owner` ("my"/"opponent"); the host resolves it
  (the live game can move either player's tiles, the preview only its own).

  ## Host requirements

  A LiveView that `use`s this module must:

    * implement `apply_game_action(socket, action)` returning `{:noreply, socket}`
    * assign `:abilities_open`, `:on_hits_open`, `:create_token_open`,
      `:create_proxy_token_open`, and `:proxy_tokens_expanded` in `mount/3`
      (the sidebar dropdown toggles read/flip these).

  New sidebar/tile functionality therefore only needs: a transform + a
  `GameState.transform/2` clause, one `handle_event` clause here, and the UI
  button — both LiveViews pick it up automatically.
  """

  defmacro __using__(_opts) do
    quote do
      # --- Damage ---
      def handle_event("toggle_damage", %{"type" => type}, socket) do
        apply_game_action(socket, {:toggle_damage, validate_damage_type(type)})
      end

      def handle_event("change_damage", %{"type" => type, "delta" => delta}, socket) do
        apply_game_action(
          socket,
          {:change_damage, validate_damage_type(type), String.to_integer(delta)}
        )
      end

      # --- Go Again / Amp ---
      def handle_event("toggle_goagain", _params, socket) do
        apply_game_action(socket, {:toggle_goagain})
      end

      def handle_event("toggle_amp", _params, socket) do
        apply_game_action(socket, {:toggle_amp})
      end

      def handle_event("change_amp", %{"delta" => delta}, socket) do
        apply_game_action(socket, {:change_amp, String.to_integer(delta)})
      end

      # --- Custom counters ---
      def handle_event("add_custom_counter", %{"name" => name}, socket) do
        apply_game_action(socket, {:add_custom_counter, name})
      end

      def handle_event("change_custom_counter", %{"id" => id, "delta" => delta}, socket) do
        apply_game_action(socket, {:change_custom_counter, id, String.to_integer(delta)})
      end

      def handle_event("remove_custom_counter", %{"id" => id}, socket) do
        apply_game_action(socket, {:remove_custom_counter, id})
      end

      # --- Effects ---
      def handle_event("toggle_effect", %{"type" => type, "category" => category}, socket) do
        apply_game_action(socket, {:toggle_effect, category, type})
      end

      def handle_event(
            "change_effect_count",
            %{"type" => type, "category" => category, "delta" => delta},
            socket
          ) do
        apply_game_action(
          socket,
          {:change_effect_count, category, type, String.to_integer(delta)}
        )
      end

      # --- Proxy tokens ---
      def handle_event("add_proxy_token", %{"type" => name}, socket) do
        apply_game_action(socket, {:add_proxy_token, name})
      end

      def handle_event("remove_proxy_token", %{"type" => name}, socket) do
        apply_game_action(socket, {:remove_proxy_token, name})
      end

      def handle_event("toggle_proxy_token", %{"type" => name}, socket) do
        apply_game_action(socket, {:toggle_proxy_token, name})
      end

      # --- Life / chain ---
      def handle_event("change_life", %{"delta" => delta}, socket) do
        apply_game_action(socket, {:change_life, String.to_integer(delta)})
      end

      def handle_event("reset_board", _params, socket) do
        apply_game_action(socket, {:reset_board})
      end

      # --- Tiles --- (owner is resolved by the host's apply_game_action/2)
      def handle_event(
            "move_tile",
            %{"tile_id" => tile_id, "x" => x, "y" => y, "owner" => owner},
            socket
          ) do
        apply_game_action(socket, {:move_tile, owner, tile_id, to_float(x), to_float(y)})
      end

      # --- Sidebar dropdown toggles (pure UI assigns, identical everywhere) ---
      def handle_event("toggle_dropdown", %{"name" => "abilities"}, socket) do
        {:noreply, assign(socket, :abilities_open, !socket.assigns.abilities_open)}
      end

      def handle_event("toggle_dropdown", %{"name" => "on_hits"}, socket) do
        new_open = !socket.assigns.on_hits_open

        {:noreply,
         socket
         |> assign(:on_hits_open, new_open)
         |> assign(:create_token_open, new_open && socket.assigns.create_token_open)}
      end

      def handle_event("toggle_dropdown", %{"name" => "create_token"}, socket) do
        {:noreply, assign(socket, :create_token_open, !socket.assigns.create_token_open)}
      end

      def handle_event("toggle_dropdown", %{"name" => "create_proxy_token"}, socket) do
        {:noreply,
         assign(socket, :create_proxy_token_open, !socket.assigns.create_proxy_token_open)}
      end

      def handle_event("toggle_dropdown", %{"name" => "proxy_tokens_panel"}, socket) do
        {:noreply, assign(socket, :proxy_tokens_expanded, !socket.assigns.proxy_tokens_expanded)}
      end

      # --- Shared param coercion helpers ---
      defp validate_damage_type("physical"), do: :physical
      defp validate_damage_type("arcane"), do: :arcane

      defp to_float(val) when is_float(val), do: val
      defp to_float(val) when is_integer(val), do: val * 1.0

      defp to_float(val) when is_binary(val) do
        case Float.parse(val) do
          {f, _} -> f
          :error -> 0.0
        end
      end
    end
  end
end
