defmodule TabletopWeb.GameComponents do
  @moduledoc """
  Shared UI components for the game view, used by both the live game
  and the camera test page.
  """
  use Phoenix.Component

  import TabletopWeb.CoreComponents, only: [icon: 1]

  attr :game_state, :any, required: true

  def game_sidebar(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 p-2 bg-base-200 border-r border-base-300 w-36 overflow-y-auto">
      <button type="button" class="btn btn-success">Begin turn</button>

      <%!-- Physical Damage --%>
      <div class="bg-warning/20 rounded p-2">
        <div class="flex items-center gap-1 mb-1">
          <input
            type="checkbox"
            class="checkbox checkbox-xs checkbox-warning"
            checked={@game_state.my.physical.active}
            phx-click="toggle_damage"
            phx-value-type="physical"
          />
          <span class="text-xs font-semibold">Physical</span>
        </div>
        <div class="flex items-center justify-between">
          <button
            type="button"
            class="btn btn-xs btn-circle btn-error"
            phx-click="change_damage"
            phx-value-type="physical"
            phx-value-delta="-1"
          >
            -
          </button>
          <span class="text-lg font-bold">{@game_state.my.physical.damage}</span>
          <button
            type="button"
            class="btn btn-xs btn-circle btn-success"
            phx-click="change_damage"
            phx-value-type="physical"
            phx-value-delta="1"
          >
            +
          </button>
        </div>
      </div>

      <%!-- Arcane Damage --%>
      <div class="bg-info/20 rounded p-2">
        <div class="flex items-center gap-1 mb-1">
          <input
            type="checkbox"
            class="checkbox checkbox-xs checkbox-info"
            checked={@game_state.my.arcane.active}
            phx-click="toggle_damage"
            phx-value-type="arcane"
          />
          <span class="text-xs font-semibold">Arcane</span>
        </div>
        <div class="flex items-center justify-between">
          <button
            type="button"
            class="btn btn-xs btn-circle btn-error"
            phx-click="change_damage"
            phx-value-type="arcane"
            phx-value-delta="-1"
          >
            -
          </button>
          <span class="text-lg font-bold">{@game_state.my.arcane.damage}</span>
          <button
            type="button"
            class="btn btn-xs btn-circle btn-success"
            phx-click="change_damage"
            phx-value-type="arcane"
            phx-value-delta="1"
          >
            +
          </button>
        </div>
      </div>

      <%!-- Go Again --%>
      <div class="bg-success/20 rounded p-2">
        <div class="flex items-center gap-1 mb-1">
          <input
            type="checkbox"
            class="checkbox checkbox-xs checkbox-success"
            checked={@game_state.my.goagain}
            phx-click="toggle_goagain"
          />
          <span class="text-xs font-semibold">Go Again</span>
        </div>
      </div>

      <%!-- Conditions dropdown --%>
      <details class="dropdown">
        <summary class="btn btn-warning w-full">
          Conditions <.icon name="hero-chevron-down" class="size-4" />
        </summary>
        <ul class="dropdown-content menu bg-base-100 rounded-box z-30 w-40 p-2 shadow-sm">
          <%= for {_key, effect} <- Tabletop.Fab.Effects.conditions() do %>
            <li>
              <div class="flex items-center gap-1 mb-1">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-warning"
                  checked={@game_state.my.effects[effect[:name]]}
                  phx-click="toggle_effect"
                  phx-value-type={effect[:name]}
                />
                <span class="text-xs font-semibold">{effect[:name]}</span>
              </div>
            </li>
          <% end %>
        </ul>
      </details>

      <%!-- On Hits dropdown --%>
      <details class="dropdown">
        <summary class="btn btn-warning w-full">
          On Hits <.icon name="hero-chevron-down" class="size-4" />
        </summary>
        <ul class="dropdown-content menu bg-base-100 rounded-box z-30 w-40 p-2 shadow-sm">
          <%= for {_key, effect} <- Tabletop.Fab.Effects.on_hit_effects() do %>
            <li>
              <div class="flex items-center gap-1 mb-1">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-warning"
                  checked={@game_state.my.effects[effect[:name]]}
                  phx-click="toggle_effect"
                  phx-value-type={effect[:name]}
                />
                <span class="text-xs font-semibold">{effect[:name]}</span>
              </div>
            </li>
          <% end %>
        </ul>
      </details>

      <button type="button" class="btn btn-success" phx-click="reset_chain">Reset Chain</button>

      <button type="button" class="btn btn-success">End turn</button>

      <div class="flex-1"></div>

      <button type="button" class="btn">Card search</button>

      <%!-- Player life --%>
      <div class="bg-warning text-warning-content rounded p-2 text-center">
        <div class="text-2xl font-bold">{@game_state.my.life}</div>
        <div class="flex justify-center gap-1">
          <button
            type="button"
            class="btn btn-xs btn-circle btn-success"
            phx-click="change_life"
            phx-value-delta="1"
          >
            +
          </button>
          <button
            type="button"
            class="btn btn-xs btn-circle btn-error"
            phx-click="change_life"
            phx-value-delta="-1"
          >
            -
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :game_state, :any, required: true

  def game_overlays(assigns) do
    ~H"""
    <%= if @game_state.my.goagain or @game_state.opponent.goagain do %>
      <div class="absolute bottom-2 left-2 bg-base-200/80 rounded px-2 py-1 text-sm font-semibold">
        Go Again active
      </div>
    <% end %>

    <%= if @game_state.my.physical.active or @game_state.opponent.physical.active do %>
      <div class="absolute bottom-12 left-2 bg-base-200/80 rounded px-2 py-1 text-sm font-semibold">
        Physical Damage active <%= @game_state.my.physical.damage + @game_state.opponent.physical.damage %>
      </div>
    <% end %>

    <%= if @game_state.my.arcane.active or @game_state.opponent.arcane.active do %>
      <div class="absolute bottom-22 left-2 bg-base-200/80 rounded px-2 py-1 text-sm font-semibold">
        Arcane Damage active <%= @game_state.my.arcane.damage + @game_state.opponent.arcane.damage %>
      </div>
    <% end %>

    <%!-- Opponent life --%>
    <div class="absolute bottom-2 right-2 bg-warning text-warning-content rounded p-2 text-center">
      <div class="text-2xl font-bold">{@game_state.opponent.life}</div>
    </div>
    """
  end
end
