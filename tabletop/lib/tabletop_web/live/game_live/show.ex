defmodule TabletopWeb.GameLive.Show do
  require Logger

  use TabletopWeb, :live_view
  use TabletopWeb.CardLookup
  use TabletopWeb.GameControls

  alias Tabletop.Games
  alias Tabletop.Games.LeaveTimer
  alias Tabletop.Games.GameSession
  alias Tabletop.Tournaments

  on_mount {TabletopWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    # get_game/2 is participant-scoped — it returns {:error, :not_found} both for
    # unknown games and for a user who isn't a participant *yet*.
    case Games.get_game(scope, id) do
      {:ok, game} ->
        mount_game(socket, game, scope)

      {:error, :not_found} ->
        # If the game exists, route the would-be joiner through pre-join so they
        # can join properly instead of dead-ending here with a 404. Possession
        # of the UUID is the invitation (same model as pre-join's own lookup).
        # This also recovers anyone whose stale `camera-confirmed` flag skipped
        # them past the join onto this page as a non-participant.
        case Games.fetch_game(id) do
          {:ok, _game} ->
            {:ok, redirect(socket, to: ~p"/games/#{id}/pre-join")}

          {:error, :not_found} ->
            {:ok,
             socket
             |> put_flash(:error, "Game not found.")
             |> redirect(to: ~p"/")}
        end
    end
  end

  defp mount_game(socket, game, scope) do
    user_id = scope.user.id

    if Games.user_part_of_game?(scope, game) do
      if connected?(socket) do
        Games.subscribe_games(scope)
        Phoenix.PubSub.subscribe(Tabletop.PubSub, "game_session:#{game.id}")
        LeaveTimer.cancel_leave(game.id, user_id)
        LeaveTimer.track_connection(game.id, user_id)
        Games.rejoin_game(scope, game)
        GameSession.ensure_started(game)
      end

      session_state =
        if connected?(socket), do: GameSession.get_state(game.id), else: empty_state()

      user_token = Phoenix.Token.sign(socket, "user socket", user_id)
      camera_relay_token = Phoenix.Token.sign(socket, "camera relay", user_id)

      qr_url = "#{TabletopWeb.Endpoint.url()}/phone-camera/#{camera_relay_token}"
      qr_svg = qr_url |> EQRCode.encode() |> EQRCode.svg(width: 200)

      {:ok,
       socket
       |> assign(:page_title, game.title)
       |> assign(:game, game)
       |> assign(:user_token, user_token)
       |> assign(:user_id, user_id)
       |> assign(:user1_id, game.user_id)
       |> assign(:user2_id, game.user2_id)
       |> assign(:camera_relay_token, camera_relay_token)
       |> assign(:qr_svg, qr_svg)
       |> assign(:peer_connected, false)
       |> assign_session_state(session_state)
       |> assign(:abilities_open, false)
       |> assign(:on_hits_open, false)
       |> assign(:create_token_open, false)
       |> assign(:create_proxy_token_open, false)
       |> assign(:proxy_tokens_expanded, false)
       |> assign(:preview_open, false)
       |> assign(:open_cards, [])
       |> assign(:tournament_match, Tournaments.get_match_by_game_id(game.id))
       |> assign(:show_leave_modal, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You are not a participant in this game.")
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- User events ---

  @impl true
  def handle_event("peer_connected", _params, socket) do
    {:noreply, assign(socket, :peer_connected, true)}
  end

  def handle_event("peer_disconnected", _params, socket) do
    {:noreply, assign(socket, :peer_connected, false)}
  end

  def handle_event("toggle_preview", _params, socket) do
    {:noreply, assign(socket, :preview_open, !socket.assigns.preview_open)}
  end

  def handle_event("open_leave_modal", _params, socket) do
    {:noreply, assign(socket, :show_leave_modal, true)}
  end

  def handle_event("close_leave_modal", _params, socket) do
    {:noreply, assign(socket, :show_leave_modal, false)}
  end

  def handle_event("leave_with_result", %{"result" => result}, socket) do
    match = socket.assigns.tournament_match
    scope = socket.assigns.current_scope

    case Tournaments.report_result(scope, match.id, result) do
      {:ok, _} ->
        LeaveTimer.cancel_leave(socket.assigns.game.id, socket.assigns.user_id)
        Games.terminate_game(scope, socket.assigns.game)

        {:noreply,
         socket
         |> put_flash(:info, "Result reported. The game has ended.")
         |> push_navigate(to: ~p"/tournaments/#{match.tournament_id}")}

      {:error, _} ->
        LeaveTimer.cancel_leave(socket.assigns.game.id, socket.assigns.user_id)
        Games.terminate_game(scope, socket.assigns.game)

        {:noreply,
         socket
         |> put_flash(:error, "Couldn't report result, but the game has ended.")
         |> push_navigate(to: ~p"/tournaments/#{match.tournament_id}")}
    end
  end

  def handle_event("set_media", %{"kind" => kind, "value" => value}, socket)
      when kind in ["mic", "camera"] and is_boolean(value) do
    dispatch(socket, {:set_media, String.to_existing_atom(kind), value})
  end

  def handle_event("leave_game", _params, socket) do
    LeaveTimer.cancel_leave(socket.assigns.game.id, socket.assigns.user_id)
    Games.terminate_game(socket.assigns.current_scope, socket.assigns.game)

    redirect_to =
      case socket.assigns.tournament_match do
        %{tournament_id: tid} -> ~p"/tournaments/#{tid}"
        _ -> ~p"/"
      end

    {:noreply,
     socket
     |> put_flash(:info, "The game has ended.")
     |> push_navigate(to: redirect_to)}
  end

  # --- PubSub messages ---

  @impl true
  def handle_info({:game_update, "game_ended", _sender_id}, socket) do
    # Play the end cue now, then defer the redirect so the sound isn't cut off
    # when the LiveView is torn down by navigation.
    Process.send_after(self(), :navigate_home, 800)

    {:noreply,
     socket
     |> put_flash(:info, "The game has ended.")
     |> push_event("play_sound", %{cue: "game_ended"})}
  end

  def handle_info(:navigate_home, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_info({:game_update, side, delta, actor_user_id}, socket)
      when side in [:user1, :user2] do
    state = GameSession.get_state(socket.assigns.game.id)
    socket = assign_session_state(socket, state)
    {:noreply, maybe_play_cue(socket, delta, actor_user_id)}
  end

  def handle_info({:session_reset, state}, socket) do
    {:noreply, assign_session_state(socket, state)}
  end

  def handle_info(
        {:updated, %Tabletop.Games.Game{id: id} = game},
        %{assigns: %{game: %{id: id}}} = socket
      ) do
    if game.user2_id != socket.assigns.user2_id do
      GameSession.set_user2(game.id, game.user2_id)
    end

    {:noreply,
     socket
     |> assign(:game, game)
     |> assign(:user2_id, game.user2_id)}
  end

  def handle_info(
        {:deleted, %Tabletop.Games.Game{id: id}},
        %{assigns: %{game: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "The current game was deleted.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({type, %Tabletop.Games.Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end

  # Emit an audio cue to this client for a state delta. Media toggles only play
  # for the *opponent's* action — the actor already hears an instant local blip
  # from the .GameVideo hook, so the actor's own server cue is suppressed.
  defp maybe_play_cue(socket, {:media_changed, kind, value}, actor_user_id) do
    if actor_user_id == socket.assigns.user_id do
      socket
    else
      case media_cue(kind, value) do
        nil -> socket
        cue -> push_event(socket, "play_sound", %{cue: cue})
      end
    end
  end

  defp maybe_play_cue(socket, _delta, _actor_user_id), do: socket

  defp media_cue(:mic, true), do: "mic_on"
  defp media_cue(:mic, false), do: "mic_off"
  defp media_cue(:camera, true), do: "camera_on"
  defp media_cue(:camera, false), do: "camera_off"
  defp media_cue(_kind, _value), do: nil

  # Callback for `TabletopWeb.GameControls`: apply an action authoritatively via
  # the game session. `move_tile` arrives with a raw owner ("my"/"opponent")
  # which we resolve to the target user so either player's tiles can be dragged.
  def apply_game_action(socket, {:move_tile, owner, tile_id, x, y}) do
    target_user_id =
      case owner do
        "my" -> socket.assigns.user_id
        "opponent" -> opponent_user_id(socket.assigns)
      end

    dispatch(socket, {:move_tile, target_user_id, tile_id, x, y})
  end

  def apply_game_action(socket, action), do: dispatch(socket, action)

  defp dispatch(socket, action) do
    case GameSession.apply_action(socket.assigns.game.id, socket.assigns.user_id, action) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Action error: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Action error: #{inspect(reason)}")}
    end
  end

  defp assign_session_state(socket, %{user1: user1, user2: user2}) do
    user_id = socket.assigns.user_id
    user1_id = socket.assigns.user1_id

    {my, opponent} =
      if user_id == user1_id, do: {user1, user2}, else: {user2, user1}

    socket
    |> assign(:user1_state, user1)
    |> assign(:user2_state, user2)
    |> assign(:game_state, %{my: my, opponent: opponent})
  end

  defp empty_state do
    default = Tabletop.Fab.GameState.default_player()
    %{user1: default, user2: default}
  end

  defp opponent_user_id(%{user_id: user_id, user1_id: user1_id, user2_id: user2_id}) do
    if user_id == user1_id, do: user2_id, else: user1_id
  end

  # Tournament match helpers (mirrored from TournamentLive.Show).
  def my_side(%{player1_id: id}, id, :win), do: "p1_win"
  def my_side(%{player1_id: id}, id, :loss), do: "p2_win"
  def my_side(%{player2_id: id}, id, :win), do: "p2_win"
  def my_side(%{player2_id: id}, id, :loss), do: "p1_win"

  def reported_by(%{player1_id: id, player1_reported: r}, id), do: r
  def reported_by(%{player2_id: id, player2_reported: r}, id), do: r
  def reported_by(_, _), do: nil

  def needs_result_prompt?(nil, _), do: false

  def needs_result_prompt?(match, user_id) do
    match.confirmed_result == nil && is_nil(reported_by(match, user_id))
  end

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val * 1.0

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if game = socket.assigns[:game] do
      # Phoenix would clean these up on process exit anyway, but being explicit
      # makes the subscription lifecycle obvious.
      Phoenix.PubSub.unsubscribe(Tabletop.PubSub, "game_session:#{game.id}")
      Phoenix.PubSub.unsubscribe(Tabletop.PubSub, "games")

      if scope = socket.assigns[:current_scope] do
        user_id = scope.user.id
        LeaveTimer.schedule_leave(game.id, user_id, scope)
      end
    end

    :ok
  end
end
