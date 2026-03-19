defmodule TabletopWeb.GameComponents do
  @moduledoc """
  Shared UI components for the game view, used by both the live game
  and the camera setup page.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.ColocatedHook
  import TabletopWeb.CoreComponents, only: [icon: 1]

  attr :game_state, :any, required: true
  attr :abilities_open, :boolean, default: false
  attr :on_hits_open, :boolean, default: false

  def game_sidebar(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 p-2 bg-base-200 border-r border-base-300 w-36 overflow-y-auto">
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

      <%!-- Abilities dropdown --%>
      <div class="relative">
        <button
          type="button"
          class="btn btn-warning w-full"
          phx-click="toggle_dropdown"
          phx-value-name="abilities"
        >
          Abilities
          <.icon
            name={if @abilities_open, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-4"
          />
        </button>
        <ul
          :if={@abilities_open}
          class="absolute z-30 menu bg-base-100 rounded-box w-40 p-2 shadow-sm mt-1"
        >
          <%= for {_key, effect} <- Tabletop.Fab.Effects.abilities() do %>
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
      </div>

      <%!-- On Hits dropdown --%>
      <div class="relative">
        <button
          type="button"
          class="btn btn-warning w-full"
          phx-click="toggle_dropdown"
          phx-value-name="on_hits"
        >
          On Hits
          <.icon
            name={if @on_hits_open, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-4"
          />
        </button>
        <ul
          :if={@on_hits_open}
          class="absolute z-30 menu bg-base-100 rounded-box w-40 p-2 shadow-sm mt-1"
        >
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
      </div>

      <button type="button" class="btn btn-success" phx-click="reset_chain">Reset Chain</button>

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
  attr :context, :atom, default: :remote

  def game_tiles(assigns) do
    # Remote canvas: only opponent's tiles (my tiles show on my preview)
    # Local/expanded preview: only my tiles (I manage my own tiles here)
    tiles =
      case assigns.context do
        :remote -> build_tiles(assigns.game_state.opponent, "opponent")
        _ -> build_tiles(assigns.game_state.my, "my")
      end

    assigns = assign(assigns, :tiles, tiles)

    ~H"""
    <%= for tile <- @tiles do %>
      <div
        class={[
          "absolute select-none z-20 rounded shadow-md whitespace-nowrap font-semibold",
          case @context do
            :local -> "pointer-events-none px-1 py-0.5 text-[8px]"
            :expanded -> "cursor-grab active:cursor-grabbing px-2 py-1 text-xs"
            _ -> "pointer-events-none px-2 py-1 text-xs"
          end,
          tile_color_class(tile)
        ]}
        style={"left: #{tile.x}%; top: #{tile.y}%; transform: translate(-50%, -50%);"}
        data-tile-id={tile.id}
        data-tile-owner={tile.owner}
        phx-hook={if @context == :expanded, do: "TabletopWeb.GameComponents.DraggableTile"}
        id={"tile-#{@context}-#{tile.owner}-#{tile.id}"}
      >
        {tile.label}
      </div>
    <% end %>

    <%!-- Opponent life (not in local preview) --%>
    <div
      :if={@context != :local}
      class="absolute bottom-2 right-2 bg-warning text-warning-content rounded p-2 text-center z-10"
    >
      <div class="text-2xl font-bold">{@game_state.opponent.life}</div>
    </div>

    <script :type={ColocatedHook} name=".DraggableTile">
      export default {
        mounted() {
          const el = this.el
          const tileId = el.dataset.tileId
          const owner = el.dataset.tileOwner

          let isDragging = false
          let currentDragPos = null

          const toPercent = (clientX, clientY) => {
            const container = el.parentElement
            const rect = container.getBoundingClientRect()
            const x = ((clientX - rect.left) / rect.width) * 100
            const y = ((clientY - rect.top) / rect.height) * 100
            return {
              x: Math.max(0, Math.min(100, x)),
              y: Math.max(0, Math.min(100, y))
            }
          }

          let startX = 0, startY = 0
          const DRAG_THRESHOLD = 3

          const onPointerDown = (e) => {
            if (e.button !== 0) return

            startX = e.clientX
            startY = e.clientY
            el.setPointerCapture(e.pointerId)
          }

          const onPointerMove = (e) => {
            if (!el.hasPointerCapture(e.pointerId)) return

            if (!isDragging) {
              const dx = e.clientX - startX
              const dy = e.clientY - startY
              if (Math.abs(dx) < DRAG_THRESHOLD && Math.abs(dy) < DRAG_THRESHOLD) return
              isDragging = true
              el.style.cursor = "grabbing"
              el.style.zIndex = "50"
            }

            const pos = toPercent(e.clientX, e.clientY)
            currentDragPos = pos
            el.style.left = pos.x + "%"
            el.style.top = pos.y + "%"
          }

          const onPointerUp = (e) => {
            if (!el.hasPointerCapture(e.pointerId)) return
            el.releasePointerCapture(e.pointerId)

            if (!isDragging) return
            isDragging = false
            currentDragPos = null
            el.style.cursor = ""
            el.style.zIndex = ""

            const pos = toPercent(e.clientX, e.clientY)
            this.pushEvent("move_tile", {
              tile_id: tileId,
              owner: owner,
              x: pos.x,
              y: pos.y
            })
          }

          el.addEventListener("pointerdown", onPointerDown)
          el.addEventListener("pointermove", onPointerMove)
          el.addEventListener("pointerup", onPointerUp)
          el.addEventListener("pointercancel", onPointerUp)

          el.style.touchAction = "none"

          this._cleanup = () => {
            el.removeEventListener("pointerdown", onPointerDown)
            el.removeEventListener("pointermove", onPointerMove)
            el.removeEventListener("pointerup", onPointerUp)
            el.removeEventListener("pointercancel", onPointerUp)
          }

          this._isDragging = () => isDragging
          this._currentDragPos = () => currentDragPos
        },

        updated() {
          if (this._isDragging && this._isDragging()) {
            const pos = this._currentDragPos()
            if (pos) {
              this.el.style.left = pos.x + "%"
              this.el.style.top = pos.y + "%"
            }
          }
        },

        destroyed() {
          if (this._cleanup) this._cleanup()
        }
      }
    </script>
    """
  end

  defp build_tiles(player_state, owner) do
    tiles = []

    tiles =
      if player_state.goagain do
        pos = Map.get(player_state.tile_positions, "goagain", %{x: 50.0, y: 80.0})

        [
          %{id: "goagain", owner: owner, label: "Go Again", x: pos.x, y: pos.y, type: :goagain}
          | tiles
        ]
      else
        tiles
      end

    tiles =
      if player_state.physical.active do
        pos = Map.get(player_state.tile_positions, "physical", %{x: 20.0, y: 60.0})
        label = "Physical #{player_state.physical.damage}"

        [
          %{id: "physical", owner: owner, label: label, x: pos.x, y: pos.y, type: :physical}
          | tiles
        ]
      else
        tiles
      end

    tiles =
      if player_state.arcane.active do
        pos = Map.get(player_state.tile_positions, "arcane", %{x: 80.0, y: 60.0})
        label = "Arcane #{player_state.arcane.damage}"

        [
          %{id: "arcane", owner: owner, label: label, x: pos.x, y: pos.y, type: :arcane}
          | tiles
        ]
      else
        tiles
      end

    Enum.reduce(player_state.effects, tiles, fn {name, active}, acc ->
      if active do
        pos = Map.get(player_state.tile_positions, name, %{x: 50.0, y: 50.0})
        [%{id: name, owner: owner, label: name, x: pos.x, y: pos.y, type: :effect} | acc]
      else
        acc
      end
    end)
  end

  defp tile_color_class(%{owner: "my", type: :goagain}), do: "bg-success text-success-content"
  defp tile_color_class(%{owner: "my", type: :physical}), do: "bg-warning text-warning-content"
  defp tile_color_class(%{owner: "my", type: :arcane}), do: "bg-info text-info-content"
  defp tile_color_class(%{owner: "my", type: :effect}), do: "bg-secondary text-secondary-content"

  defp tile_color_class(%{owner: "opponent", type: :goagain}),
    do: "bg-success/60 text-success-content border border-success"

  defp tile_color_class(%{owner: "opponent", type: :physical}),
    do: "bg-warning/60 text-warning-content border border-warning"

  defp tile_color_class(%{owner: "opponent", type: :arcane}),
    do: "bg-info/60 text-info-content border border-info"

  defp tile_color_class(%{owner: "opponent", type: :effect}),
    do: "bg-secondary/60 text-secondary-content border border-secondary"

  defp pitch_color_class(1), do: "bg-red-500"
  defp pitch_color_class(2), do: "bg-yellow-400"
  defp pitch_color_class(3), do: "bg-blue-500"
  defp pitch_color_class(_), do: "bg-base-300"

  attr :open_cards, :list, required: true

  def card_popouts(assigns) do
    ~H"""
    <%= for card <- @open_cards do %>
      <div
        id={"card-popout-#{card.id}"}
        phx-hook=".DraggableCardPopout"
        data-x={card.x}
        data-y={card.y}
        class="absolute z-30 w-64 bg-base-100 border border-base-300 rounded-lg shadow-xl overflow-hidden"
        style="left: 0; top: 0;"
      >
        <div class="card-popout-header flex items-center justify-between px-3 py-2 bg-base-200 cursor-grab active:cursor-grabbing touch-none">
          <span class="font-semibold text-sm truncate flex-1">
            {card.card.name}
          </span>
          <button
            type="button"
            phx-click="close_card"
            phx-value-id={card.id}
            class="btn btn-circle btn-xs btn-error ml-2"
            title="Close"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
        <div class="p-3 space-y-2">
          <img
            src={card.card.image_url}
            alt={card.card.name}
            class="w-full rounded"
          />
          <%= if length(Map.get(card, :pitch_variants, [])) > 1 do %>
            <div class="flex items-center justify-center gap-2 pt-1">
              <%= for variant <- card.pitch_variants do %>
                <button
                  type="button"
                  phx-click="switch_pitch"
                  phx-value-id={card.id}
                  phx-value-pitch={variant.pitch}
                  class={[
                    "w-6 h-6 rounded-full border-2 transition-transform",
                    pitch_color_class(variant.pitch),
                    if(variant.pitch == card.card.pitch,
                      do: "scale-125 border-base-content",
                      else: "border-transparent opacity-60 hover:opacity-100"
                    )
                  ]}
                  title={"Pitch #{variant.pitch}"}
                />
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <script :type={ColocatedHook} name=".DraggableCardPopout">
      export default {
        mounted() {
          const el = this.el
          const header = el.querySelector(".card-popout-header")
          const container = el.parentElement

          const initX = parseFloat(el.dataset.x || "10")
          const initY = parseFloat(el.dataset.y || "10")
          const maxX = container.clientWidth - el.offsetWidth
          const maxY = container.clientHeight - el.offsetHeight
          el.style.left = Math.max(0, Math.min(initX, maxX)) + "px"
          el.style.top = Math.max(0, Math.min(initY, maxY)) + "px"

          // Track position so updated() can restore it after LiveView re-renders
          this._currentLeft = el.style.left
          this._currentTop = el.style.top

          let offsetX = 0
          let offsetY = 0

          this.updated = () => {
            // LiveView re-renders reset the inline style to "left: 0; top: 0;".
            // Reapply the last known position so the popout doesn't jump on pitch switch.
            el.style.left = this._currentLeft
            el.style.top = this._currentTop
          }

          header.addEventListener("pointerdown", (e) => {
            if (e.target.closest("button")) return
            e.preventDefault()
            header.setPointerCapture(e.pointerId)
            offsetX = e.clientX - el.getBoundingClientRect().left
            offsetY = e.clientY - el.getBoundingClientRect().top
            header.style.cursor = "grabbing"

            container.querySelectorAll("[id^='card-popout-']").forEach((p) => {
              p.style.zIndex = "30"
            })
            el.style.zIndex = "31"
          })

          header.addEventListener("pointermove", (e) => {
            if (!header.hasPointerCapture(e.pointerId)) return
            const rect = container.getBoundingClientRect()
            let newX = e.clientX - rect.left - offsetX
            let newY = e.clientY - rect.top - offsetY
            newX = Math.max(0, Math.min(newX, container.clientWidth - el.offsetWidth))
            newY = Math.max(0, Math.min(newY, container.clientHeight - el.offsetHeight))
            el.style.left = newX + "px"
            el.style.top = newY + "px"
            this._currentLeft = el.style.left
            this._currentTop = el.style.top
          })

          const onPointerEnd = (e) => {
            if (!header.hasPointerCapture(e.pointerId)) return
            header.releasePointerCapture(e.pointerId)
            header.style.cursor = "grab"
          }

          header.addEventListener("pointerup", onPointerEnd)
          header.addEventListener("pointercancel", onPointerEnd)
        },
      }
    </script>
    """
  end
end
