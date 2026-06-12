defmodule TabletopWeb.GameComponents do
  @moduledoc """
  Shared UI components for the game view, used by both the live game
  and the camera setup page.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.ColocatedHook
  import TabletopWeb.CoreComponents, only: [icon: 1]
  import Phoenix.HTML, only: [raw: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: TabletopWeb.Endpoint,
    router: TabletopWeb.Router,
    statics: TabletopWeb.static_paths()

  attr :tile, :map, required: true

  defp tile_hover_preview(assigns) do
    img = Map.get(assigns.tile, :card_img_src)
    desc = Map.get(assigns.tile, :description_html)

    # Anchor the popover on the side with more room so it never gets clipped.
    horizontal_class =
      if assigns.tile.x > 50, do: "right-full mr-2", else: "left-full ml-2"

    vertical_class =
      if assigns.tile.y > 50, do: "bottom-0", else: "top-0"

    assigns =
      assigns
      |> assign(:img, if(img in [nil, ""], do: nil, else: img))
      |> assign(
        :desc,
        if(desc in [nil, ""], do: nil, else: Tabletop.Fab.Effects.render_description(desc))
      )
      |> assign(:position_class, "#{horizontal_class} #{vertical_class}")

    ~H"""
    <div
      :if={@img || @desc}
      class={[
        "pointer-events-none absolute z-50 hidden group-hover:block",
        @position_class
      ]}
    >
      <img
        :if={@img}
        src={@img}
        alt={@tile.label}
        class="max-w-[16rem] rounded shadow-lg bg-base-100"
      />
      <div
        :if={!@img && @desc}
        class="w-64 max-w-[16rem] rounded shadow-lg bg-base-100 text-base-content p-2 text-xs leading-snug font-normal normal-case tracking-normal space-y-1 whitespace-normal break-words"
      >
        {raw(@desc)}
      </div>
    </div>
    """
  end

  attr :game_state, :any, required: true
  attr :abilities_open, :boolean, default: false
  attr :on_hits_open, :boolean, default: false
  attr :create_token_open, :boolean, default: false
  attr :create_proxy_token_open, :boolean, default: false

  def game_sidebar(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 p-2 bg-base-200 border-r border-base-300 w-36 overflow-visible">
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
          class="btn w-full bg-purple-300 hover:bg-purple-400 text-purple-950 border-purple-400"
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
          class="absolute z-30 menu bg-base-100 rounded-box w-36 p-2 shadow-sm mt-1"
        >
          <%= for {_key, effect} <- Tabletop.Fab.Effects.abilities() do %>
            <li>
              <label class="flex items-center gap-1 mb-1 cursor-pointer w-full">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs accent-purple-400"
                  checked={
                    @game_state.my.effects[
                      Tabletop.Fab.GameState.effect_key("ability", effect[:name])
                    ]
                  }
                  phx-click="toggle_effect"
                  phx-value-type={effect[:name]}
                  phx-value-category="ability"
                />
                <.icon :if={effect[:icon] not in [nil, ""]} name={effect[:icon]} class="size-5" />
                <span class="text-xs font-semibold">{effect[:name]}</span>
              </label>
            </li>
          <% end %>
        </ul>
      </div>

      <%!-- On Hits dropdown --%>
      <div class="relative">
        <button
          type="button"
          class="btn w-full bg-orange-400 hover:bg-orange-500 text-orange-950 border-orange-500"
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
          class="absolute z-30 list-none bg-base-100 rounded-box p-2 shadow-sm mt-1 grid grid-cols-2 gap-x-4 gap-y-1 w-[28rem]"
        >
          <%= for {_key, effect} <- Tabletop.Fab.Effects.on_hit_effects() do %>
            <li class="flex items-center gap-1">
              <%= if effect[:popup] do %>
                <button
                  type="button"
                  class="flex items-center gap-1 flex-1 min-w-0 text-left hover:bg-base-200 rounded px-0.5 py-0.5"
                  phx-click="toggle_dropdown"
                  phx-value-name={to_string(effect[:popup])}
                >
                  <.icon
                    :if={effect[:icon] not in [nil, ""]}
                    name={effect[:icon]}
                    class="size-5 shrink-0"
                  />
                  <span class="text-xs font-semibold leading-tight">{effect[:name]}…</span>
                </button>
              <% else %>
                <label class="flex items-center gap-1 cursor-pointer flex-1 min-w-0">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-xs accent-orange-500"
                    checked={
                      @game_state.my.effects[
                        Tabletop.Fab.GameState.effect_key("on_hit", effect[:name])
                      ]
                    }
                    phx-click="toggle_effect"
                    phx-value-type={effect[:name]}
                    phx-value-category="on_hit"
                  />
                  <.icon
                    :if={effect[:icon] not in [nil, ""]}
                    name={effect[:icon]}
                    class="size-5 shrink-0"
                  />
                  <span class="text-xs font-semibold leading-tight">{effect[:name]}</span>
                </label>
                <div :if={effect[:counterable]} class="flex items-center gap-0.5 shrink-0">
                  <button
                    type="button"
                    class="btn btn-xs btn-circle btn-error"
                    phx-click="change_effect_count"
                    phx-value-type={effect[:name]}
                    phx-value-category="on_hit"
                    phx-value-delta="-1"
                  >
                    -
                  </button>
                  <span class="text-xs font-bold w-3 text-center">
                    {Map.get(
                      @game_state.my.effect_counts || %{},
                      Tabletop.Fab.GameState.effect_key("on_hit", effect[:name]),
                      1
                    )}
                  </span>
                  <button
                    type="button"
                    class="btn btn-xs btn-circle btn-success"
                    phx-click="change_effect_count"
                    phx-value-type={effect[:name]}
                    phx-value-category="on_hit"
                    phx-value-delta="1"
                  >
                    +
                  </button>
                </div>
              <% end %>
            </li>
          <% end %>
        </ul>

        <%!-- Create Token popup (to the right of the on-hits dropdown) --%>
        <ul
          :if={@create_token_open}
          class="absolute z-40 list-none bg-base-100 rounded-box p-2 shadow-lg mt-1 left-[calc(28rem+1.5rem)] grid grid-cols-2 gap-x-4 gap-y-1 w-[26rem] border border-base-300"
        >
          <li class="col-span-2 text-[10px] uppercase tracking-wide font-bold opacity-60 px-1 pb-1 border-b border-base-300">
            Create Token
          </li>
          <%= for {_key, token} <- Tabletop.Fab.Effects.tokens_for_player() do %>
            <li class="flex items-center gap-1">
              <label class="flex items-center gap-1 cursor-pointer flex-1 min-w-0">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs accent-emerald-500"
                  checked={
                    @game_state.my.effects[Tabletop.Fab.GameState.effect_key("token", token[:name])]
                  }
                  phx-click="toggle_effect"
                  phx-value-type={token[:name]}
                  phx-value-category="token"
                />
                <.icon
                  :if={token[:icon] not in [nil, ""]}
                  name={token[:icon]}
                  class="size-5 shrink-0"
                />
                <span class="text-xs font-semibold leading-tight">{token[:name]}</span>
              </label>
            </li>
          <% end %>
        </ul>
      </div>

      <button type="button" class="btn btn-success" phx-click="reset_chain">Reset Chain</button>

      <div class="flex-1"></div>

      <form phx-change="search_card" phx-submit="search_card" onsubmit="return false" class="relative">
        <input
          type="text"
          placeholder="Search card..."
          phx-debounce="1000"
          name="query"
          class="input input-bordered input-sm w-full pr-7 text-xs"
        />
        <.icon
          name="hero-magnifying-glass"
          class="size-3 absolute right-2 top-1/2 -translate-y-1/2 opacity-40 pointer-events-none"
        />
      </form>

      <%!-- Create Proxy Token --%>
      <div class="relative">
        <button
          type="button"
          class="btn btn-sm w-full bg-emerald-300 hover:bg-emerald-400 text-emerald-950 border-emerald-400"
          phx-click="toggle_dropdown"
          phx-value-name="create_proxy_token"
        >
          Create Proxy Token
          <.icon
            name={if @create_proxy_token_open, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-4"
          />
        </button>
        <ul
          :if={@create_proxy_token_open}
          class="absolute z-40 list-none bg-base-100 rounded-box p-2 shadow-lg mb-1 bottom-full left-full ml-2 grid grid-cols-2 gap-x-4 gap-y-1 w-[26rem] border border-base-300"
        >
          <li class="col-span-2 text-[10px] uppercase tracking-wide font-bold opacity-60 px-1 pb-1 border-b border-base-300">
            Add Proxy Token
          </li>
          <%= for {_key, token} <- Tabletop.Fab.Effects.tokens_for_opponent() do %>
            <li class="flex items-center gap-1">
              <div class="flex items-center gap-1 flex-1 min-w-0 px-0.5 py-0.5">
                <.icon
                  :if={token[:icon] not in [nil, ""]}
                  name={token[:icon]}
                  class="size-5 shrink-0"
                />
                <span class="text-xs font-semibold leading-tight">{token[:name]}</span>
              </div>
              <div class="flex items-center gap-0.5 shrink-0">
                <input
                  :if={token[:singleton]}
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-success"
                  checked={Map.get(@game_state.my.proxy_tokens || %{}, token[:name], 0) > 0}
                  phx-click="toggle_proxy_token"
                  phx-value-type={token[:name]}
                />
                <button
                  :if={!token[:singleton]}
                  type="button"
                  class="btn btn-xs btn-circle btn-error"
                  phx-click="remove_proxy_token"
                  phx-value-type={token[:name]}
                >
                  -
                </button>
                <span :if={!token[:singleton]} class="text-xs font-bold w-3 text-center">
                  {Map.get(@game_state.my.proxy_tokens || %{}, token[:name], 0)}
                </span>
                <button
                  :if={!token[:singleton]}
                  type="button"
                  class="btn btn-xs btn-circle btn-success"
                  phx-click="add_proxy_token"
                  phx-value-type={token[:name]}
                >
                  +
                </button>
              </div>
            </li>
          <% end %>
        </ul>
      </div>

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
  attr :expanded, :boolean, default: false

  def proxy_tokens_panel(assigns) do
    proxy_tokens = Map.get(assigns.game_state.my, :proxy_tokens, %{})

    tokens_by_name =
      Map.new(Tabletop.Fab.Effects.tokens(), fn {_k, t} -> {t.name, t} end)

    entries =
      proxy_tokens
      |> Enum.map(fn {name, count} -> {name, count, Map.get(tokens_by_name, name)} end)
      |> Enum.filter(fn {_n, _c, token} -> token end)
      |> Enum.sort_by(fn {name, _c, _t} -> name end)

    total = Enum.reduce(proxy_tokens, 0, fn {_n, c}, acc -> acc + c end)

    assigns =
      assigns
      |> assign(:entries, entries)
      |> assign(:total, total)

    ~H"""
    <div
      :if={@entries != []}
      class="absolute top-2 right-2 z-30 bg-base-100/95 backdrop-blur rounded-lg shadow-lg border border-base-300 text-base-content max-w-[80%]"
    >
      <button
        type="button"
        class="flex items-center gap-2 w-full px-3 py-2 hover:bg-base-200 rounded-lg text-left"
        phx-click="toggle_dropdown"
        phx-value-name="proxy_tokens_panel"
      >
        <span class="text-xs font-bold uppercase tracking-wide opacity-70">
          Proxy Tokens ({@total})
        </span>
        <div :if={!@expanded} class="flex flex-wrap items-center gap-1 flex-1 min-w-0">
          <span
            :for={{name, count, token} <- @entries}
            class="inline-flex items-center gap-1 bg-emerald-100 text-emerald-900 rounded px-1.5 py-0.5 text-[11px] font-semibold"
          >
            <.icon
              :if={token[:icon] not in [nil, ""]}
              name={token[:icon]}
              class="size-3 shrink-0"
            />
            {name}
            <span :if={count > 1} class="opacity-70">×{count}</span>
          </span>
        </div>
        <.icon
          name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="size-4 ml-auto shrink-0"
        />
      </button>

      <div :if={@expanded} class="p-2 border-t border-base-300 flex flex-wrap gap-3 max-w-[60rem]">
        <div :for={{name, count, token} <- @entries} class="flex flex-col items-center gap-1 w-60">
          <img
            :if={token[:card_img_src] not in [nil, ""]}
            src={token[:card_img_src]}
            alt={name}
            class="w-60 rounded shadow"
          />
          <div
            :if={token[:card_img_src] in [nil, ""]}
            class="w-60 h-56 rounded bg-base-200 flex items-center justify-center text-xs p-2 text-center"
          >
            {name}
          </div>
          <div class="flex items-center gap-1">
            <button
              :if={token[:singleton]}
              type="button"
              class="btn btn-xs btn-circle btn-error"
              phx-click="remove_proxy_token"
              phx-value-type={name}
              aria-label={"Remove #{name}"}
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
            <button
              :if={!token[:singleton]}
              type="button"
              class="btn btn-xs btn-circle btn-error"
              phx-click="remove_proxy_token"
              phx-value-type={name}
            >
              -
            </button>
            <span :if={!token[:singleton]} class="text-sm font-bold w-6 text-center">{count}</span>
            <button
              :if={!token[:singleton]}
              type="button"
              class="btn btn-xs btn-circle btn-success"
              phx-click="add_proxy_token"
              phx-value-type={name}
            >
              +
            </button>
          </div>
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
        :setup -> build_tiles(assigns.game_state.my, "my")
        _ -> build_tiles(assigns.game_state.my, "my")
      end

    assigns = assign(assigns, :tiles, tiles)

    ~H"""
    <%= for tile <- @tiles do %>
      <div
        class={[
          "group absolute select-none z-20 rounded-md shadow-lg ring-1 ring-black/10 whitespace-nowrap font-semibold bg-gradient-to-br flex items-center gap-1",
          case @context do
            :local ->
              "pointer-events-none px-1 py-0.5 text-[8px] gap-0.5"

            ctx when ctx in [:expanded, :setup] ->
              "cursor-grab active:cursor-grabbing px-2 py-1 text-xs gap-1.5"

            _ ->
              "px-2 py-1 text-xs gap-1.5 #{if has_hover?(tile), do: "cursor-help", else: "pointer-events-none"}"
          end,
          tile_color_class(tile)
        ]}
        style={"left: #{tile.x}%; top: #{tile.y}%; transform: translate(-50%, -50%);"}
        data-tile-id={tile.id}
        data-tile-owner={tile.owner}
        data-tile-group={tile_group_name(tile)}
        phx-hook={if @context in [:expanded, :setup], do: "TabletopWeb.GameComponents.DraggableTile"}
        id={"tile-#{@context}-#{tile.owner}-#{tile.id}"}
      >
        <span class={[
          "rounded-full bg-black/25 flex items-center justify-center shrink-0",
          case @context do
            :local -> "p-[1px]"
            _ -> "p-1"
          end
        ]}>
          <.icon
            name={tile_icon(tile)}
            class={
              case @context do
                :local -> "size-2"
                _ -> "size-3.5"
              end
            }
          />
        </span>
        <span class="uppercase tracking-wide leading-none">{tile.label}</span>
        <span
          :if={Map.get(tile, :value)}
          class={[
            "font-bold leading-none ml-0.5",
            case @context do
              :local -> "text-[10px]"
              _ -> "text-sm"
            end
          ]}
        >
          {tile.value}
        </span>
        <.tile_hover_preview :if={@context != :local} tile={tile} />
      </div>
    <% end %>

    <%!-- Opponent life (not in local preview) --%>
    <div
      :if={@context not in [:local, :setup]}
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
          const group = el.dataset.tileGroup

          let isDragging = false
          let currentDragPos = null
          let startPosPercent = null
          let siblingStarts = []

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
            startPosPercent = {
              x: parseFloat(el.style.left) || 0,
              y: parseFloat(el.style.top) || 0
            }

            siblingStarts = []
            if (group) {
              const selector = `[data-tile-group="${group}"][data-tile-owner="${owner}"]`
              const siblings = Array.from(el.parentElement.querySelectorAll(selector))
                .filter(s => s !== el)
              siblingStarts = siblings.map(s => ({
                el: s,
                left: parseFloat(s.style.left) || 0,
                top: parseFloat(s.style.top) || 0
              }))
            }

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

            if (siblingStarts.length > 0 && startPosPercent) {
              const dxPct = pos.x - startPosPercent.x
              const dyPct = pos.y - startPosPercent.y
              for (const s of siblingStarts) {
                s.el.style.left = Math.max(0, Math.min(100, s.left + dxPct)) + "%"
                s.el.style.top = Math.max(0, Math.min(100, s.top + dyPct)) + "%"
              }
            }
          }

          const onPointerUp = (e) => {
            if (!el.hasPointerCapture(e.pointerId)) return
            el.releasePointerCapture(e.pointerId)

            if (!isDragging) return
            isDragging = false
            currentDragPos = null
            startPosPercent = null
            siblingStarts = []
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

        [
          %{
            id: "physical",
            owner: owner,
            label: "Physical",
            value: player_state.physical.damage,
            x: pos.x,
            y: pos.y,
            type: :physical
          }
          | tiles
        ]
      else
        tiles
      end

    tiles =
      if player_state.arcane.active do
        pos = Map.get(player_state.tile_positions, "arcane", %{x: 80.0, y: 60.0})

        [
          %{
            id: "arcane",
            owner: owner,
            label: "Arcane",
            value: player_state.arcane.damage,
            x: pos.x,
            y: pos.y,
            type: :arcane
          }
          | tiles
        ]
      else
        tiles
      end

    abilities_by_name =
      Map.new(Tabletop.Fab.Effects.abilities(), fn {_k, e} -> {e.name, e} end)

    on_hits_by_name =
      Map.new(Tabletop.Fab.Effects.on_hit_effects(), fn {_k, e} -> {e.name, e} end)

    tokens_by_name =
      Map.new(Tabletop.Fab.Effects.tokens_for_player(), fn {_k, t} -> {t.name, t} end)

    effect_counts = Map.get(player_state, :effect_counts, %{})

    Enum.reduce(player_state.effects, tiles, fn {key, active}, acc ->
      if active do
        pos = Map.get(player_state.tile_positions, key, %{x: 50.0, y: 50.0})
        {category, name} = parse_effect_key(key)

        {effect, type} =
          case category do
            "ability" -> {Map.get(abilities_by_name, name), :ability}
            "on_hit" -> {Map.get(on_hits_by_name, name), :on_hit}
            "token" -> {Map.get(tokens_by_name, name), :token}
            _ -> {nil, :effect}
          end

        value = if effect && effect[:counterable], do: Map.get(effect_counts, key, 1)

        [
          %{
            id: key,
            owner: owner,
            label: name,
            value: value,
            x: pos.x,
            y: pos.y,
            type: type,
            icon: effect && effect[:icon],
            card_img_src: effect && effect[:card_img_src],
            description_html: effect && effect[:description_html]
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp parse_effect_key(key) do
    case String.split(key, ":", parts: 2) do
      [category, name] -> {category, name}
      [name] -> {nil, name}
    end
  end

  defp has_hover?(tile) do
    Map.get(tile, :card_img_src) not in [nil, ""] or
      Map.get(tile, :description_html) not in [nil, ""]
  end

  defp tile_color_class(%{owner: "my", type: :goagain}),
    do: "from-success to-success/70 text-success-content"

  defp tile_color_class(%{owner: "my", type: :physical}),
    do: "from-warning to-warning/70 text-warning-content"

  defp tile_color_class(%{owner: "my", type: :arcane}),
    do: "from-info to-info/70 text-info-content"

  defp tile_color_class(%{owner: "my", type: :ability}),
    do: "from-purple-300 to-purple-400/70 text-purple-950"

  defp tile_color_class(%{owner: "my", type: :on_hit}),
    do: "from-orange-400 to-orange-500/70 text-orange-950"

  defp tile_color_class(%{owner: "my", type: :token}),
    do: "from-emerald-300 to-emerald-400/70 text-emerald-950"

  defp tile_color_class(%{owner: "my", type: :effect}),
    do: "from-secondary to-secondary/70 text-secondary-content"

  defp tile_color_class(%{owner: "opponent", type: :goagain}),
    do: "from-success/60 to-success/40 text-success-content border border-success"

  defp tile_color_class(%{owner: "opponent", type: :physical}),
    do: "from-warning/60 to-warning/40 text-warning-content border border-warning"

  defp tile_color_class(%{owner: "opponent", type: :arcane}),
    do: "from-info/60 to-info/40 text-info-content border border-info"

  defp tile_color_class(%{owner: "opponent", type: :ability}),
    do: "from-purple-300/60 to-purple-400/40 text-purple-950 border border-purple-400"

  defp tile_color_class(%{owner: "opponent", type: :on_hit}),
    do: "from-orange-400/60 to-orange-500/40 text-orange-950 border border-orange-500"

  defp tile_color_class(%{owner: "opponent", type: :token}),
    do: "from-emerald-300/60 to-emerald-400/40 text-emerald-950 border border-emerald-400"

  defp tile_color_class(%{owner: "opponent", type: :effect}),
    do: "from-secondary/60 to-secondary/40 text-secondary-content border border-secondary"

  defp tile_icon(%{icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp tile_icon(%{type: :goagain}), do: "hero-arrow-path"
  defp tile_icon(%{type: :physical}), do: "hero-bolt"
  defp tile_icon(%{type: :arcane}), do: "hero-sparkles"
  defp tile_icon(_), do: "hero-star"

  defp tile_group_name(%{type: :ability}), do: "ability"
  defp tile_group_name(%{type: :on_hit}), do: "on_hit"
  defp tile_group_name(%{type: :token}), do: "on_hit"
  defp tile_group_name(_), do: nil

  defp pitch_color_class(1), do: "bg-red-500"
  defp pitch_color_class(2), do: "bg-yellow-400"
  defp pitch_color_class(3), do: "bg-blue-500"
  defp pitch_color_class(_), do: "bg-base-300"

  # Hamming distance between a captured client phash (of `kind`) and the
  # corresponding stored hash on `card_print`.
  defp phash_debug_distance(_kind, _value, nil), do: nil

  defp phash_debug_distance(:art, value, %{image_phash: stored}) when is_integer(stored),
    do: Tabletop.Cards.PHash.hamming_distance(value, stored)

  defp phash_debug_distance(:art_flipped, value, %{image_phash: stored})
       when is_integer(stored),
       do: Tabletop.Cards.PHash.hamming_distance(value, stored)

  defp phash_debug_distance(:full, value, %{image_phash_full: stored}) when is_integer(stored),
    do: Tabletop.Cards.PHash.hamming_distance(value, stored)

  defp phash_debug_distance(_kind, _value, _card_print), do: nil

  # Per-kind thresholds — must mirror cards.ex. `:full` is stricter because
  # whole-card hashes share frame/border content across cards.
  defp phash_kind_threshold(:full), do: 8
  defp phash_kind_threshold(_), do: 15

  # Returns the phash `kind` with the smallest distance against the given
  # card_print *that also passes its kind's threshold* — i.e. the arm that
  # actually resolved this row. Returns nil if no kind qualifies.
  defp winning_phash_kind(phashes, card_print) when is_map(phashes) do
    phashes
    |> Enum.flat_map(fn
      {_kind, nil} ->
        []

      {kind, value} ->
        case phash_debug_distance(kind, value, card_print) do
          nil ->
            []

          d ->
            if d < phash_kind_threshold(kind), do: [{kind, d}], else: []
        end
    end)
    |> case do
      [] -> nil
      pairs -> pairs |> Enum.min_by(&elem(&1, 1)) |> elem(0)
    end
  end

  defp winning_phash_kind(_, _), do: nil

  attr :id, :string, required: true
  attr :code, :string, required: true
  attr :label, :string, default: "Share"
  attr :class, :string, default: "btn btn-sm btn-outline"
  attr :rest, :global

  def share_code_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-hook=".ShareCode"
      id={@id}
      data-code={@code}
      data-share-text={"Join my Flesh and Blood game with code: #{@code}"}
      class={@class}
      {@rest}
    >
      <.icon name="hero-share" class="size-4" /> {@label}
    </button>

    <script :type={ColocatedHook} name=".ShareCode">
      export default {
        mounted() {
          this.handleClick = async () => {
            const code = this.el.dataset.code
            const text = this.el.dataset.shareText || code
            if (!code) return

            let label = "Copied!"
            try {
              if (navigator.share) {
                await navigator.share({ title: "Join my game", text })
                label = "Shared!"
              } else {
                await navigator.clipboard.writeText(code)
              }
            } catch (err) {
              if (err && err.name === "AbortError") return
              try { await navigator.clipboard.writeText(code) } catch (_) {}
            }
            const original = this.el.innerHTML
            this.el.textContent = label
            this._t = setTimeout(() => { this.el.innerHTML = original }, 1500)
          }
          this.el.addEventListener("click", this.handleClick)
        },
        destroyed() {
          if (this._t) clearTimeout(this._t)
          if (this.handleClick) this.el.removeEventListener("click", this.handleClick)
        },
      }
    </script>
    """
  end

  attr :qr_svg, :string, required: true
  attr :show_reconfigure_link, :boolean, default: true
  attr :game_id, :string, default: nil

  def settings_dialog(assigns) do
    ~H"""
    <dialog id="settings-dialog" class="modal" phx-update="ignore">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Settings</h3>
        <div class="py-4 space-y-4">
          <label class="flex items-center justify-between cursor-pointer">
            <span class="label-text">Flip opponent's view</span>
            <input id="flip-opponent-toggle" type="checkbox" class="toggle" />
          </label>
          <label class="flex items-center justify-between cursor-pointer">
            <span class="label-text">Card scan debug overlay</span>
            <input id="debug-scan-toggle" type="checkbox" class="toggle" />
          </label>

          <div :if={@game_id} class="divider text-xs">Share game</div>
          <div :if={@game_id} class="space-y-1">
            <p class="text-sm">Share this code so your opponent can join.</p>
            <div class="flex gap-2">
              <input
                id="share-game-code"
                type="text"
                readonly
                value={@game_id}
                class="input input-sm input-bordered flex-1 font-mono text-xs"
              />
              <.share_code_button id="settings-share-code-btn" code={@game_id} label="Copy" />
            </div>
          </div>

          <div class="divider text-xs">Camera Source</div>
          <div id="camera-source-section" class="space-y-2">
            <div class="flex gap-2">
              <button
                id="use-webcam-btn"
                type="button"
                class="btn btn-sm flex-1 btn-active"
              >
                <.icon name="hero-video-camera" class="size-4" /> Webcam
              </button>
              <button
                id="use-phone-camera-btn"
                type="button"
                class="btn btn-sm flex-1 btn-outline"
                disabled
              >
                <.icon name="hero-device-phone-mobile" class="size-4" /> Phone
              </button>
            </div>
            <div id="phone-camera-status" class="text-center">
              <span class="badge badge-sm badge-outline">Phone not connected</span>
            </div>
          </div>

          <div class="divider text-xs">Phone Camera</div>
          <div id="phone-camera-qr-section">
            <p class="text-sm mb-3">Scan to connect your phone as a camera</p>
            <div class="flex justify-center">
              {raw(@qr_svg)}
            </div>
            <p class="text-xs text-center mt-2 opacity-60">
              Scan with your phone to connect
            </p>
          </div>

          <.link
            :if={@show_reconfigure_link}
            navigate={
              if @game_id,
                do: ~p"/camera-setup?#{%{redirect: "/games/#{@game_id}", game_id: @game_id}}",
                else: ~p"/camera-setup"
            }
            class="btn btn-outline btn-sm w-full"
          >
            Reconfigure Camera
          </.link>
        </div>
        <div class="modal-action">
          <form method="dialog">
            <button class="btn">Close</button>
          </form>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
    """
  end

  attr :open_cards, :list, required: true

  def card_popouts(assigns) do
    ~H"""
    <%= for card <- @open_cards do %>
      <div
        id={"card-popout-#{card.id}"}
        phx-hook=".DraggableCardPopout"
        data-x={card.x}
        data-y={card.y}
        class="absolute z-30 w-80 bg-base-100 border border-base-300 rounded-lg shadow-xl overflow-hidden"
        style="left: 0; top: 0;"
      >
        <div class="card-popout-header flex items-center justify-between px-3 py-2 bg-base-200 cursor-grab active:cursor-grabbing touch-none">
          <form
            phx-change="search_card"
            phx-submit="search_card"
            onsubmit="return false"
            class="flex-1 min-w-0"
          >
            <input type="hidden" name="_id" value={card.id} />
            <input
              type="text"
              value={card.card.name}
              phx-debounce="1000"
              name="query"
              class="font-semibold text-sm bg-transparent border-none outline-none w-full cursor-text"
              title="Edit to search for a different card"
            />
          </form>
          <button
            type="button"
            phx-click="close_card"
            phx-value-id={card.id}
            class="btn btn-circle btn-xs btn-error ml-2 flex-shrink-0"
            title="Close"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
        <div class="p-3 space-y-2">
          <img
            src={card.card_print && card.card_print.image_url}
            alt={card.card.name}
            class="w-full rounded"
          />
          <%= if length(Map.get(card, :alternate_matches, [])) > 0 do %>
            <form phx-change="switch_match" class="pt-1">
              <input type="hidden" name="card_id" value={card.id} />
              <select name="normalized_name" class="select select-bordered select-xs w-full">
                <option value="" selected>{card.card.name}</option>
                <%= for alt <- card.alternate_matches do %>
                  <option value={alt.card.normalized_name}>{alt.card.name}</option>
                <% end %>
              </select>
            </form>
          <% end %>
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
          <div class="card-popout-debug hidden border-t border-base-300 pt-2 mt-1 space-y-1 font-mono text-[10px] opacity-80">
            <div class="font-semibold text-[11px] opacity-60">Server (card DB)</div>
            <div>
              <span class="opacity-50">face_id:</span> {card.card_print && card.card_print.face_id}
            </div>
            <div>
              <span class="opacity-50">orientation:</span> {card.card_print &&
                card.card_print.orientation}
            </div>
            <%= if card.card_print && card.card_print.image_phash do %>
              <div><span class="opacity-50">phash (art):</span> {card.card_print.image_phash}</div>
            <% end %>
            <%= if card.card_print && card.card_print.image_phash_full do %>
              <div>
                <span class="opacity-50">phash (full):</span> {card.card_print.image_phash_full}
              </div>
            <% end %>
            <%= if debug = Map.get(card, :debug) do %>
              <% winning_kind = winning_phash_kind(Map.get(debug, :phashes, %{}), card.card_print) %>
              <div class="font-semibold text-[11px] opacity-60 pt-1">Client (scan)</div>
              <div><span class="opacity-50">match method:</span> {debug.match_method}</div>
              <%= if (rs = Map.get(debug, :region_scale)) && rs > 1.0 do %>
                <div>
                  <span class="opacity-50">capture region:</span>
                  <span class="ml-1 px-1.5 py-0.5 rounded bg-warning text-warning-content font-semibold">
                    expanded to {round(rs * 100)}%
                  </span>
                </div>
              <% end %>
              <%= if winning_kind do %>
                <div>
                  <span class="opacity-50">resolved by:</span>
                  <span class="ml-1 px-1.5 py-0.5 rounded bg-success text-success-content font-semibold">
                    phash:{winning_kind}
                  </span>
                </div>
              <% end %>
              <%= if debug[:detected_pitch] do %>
                <div>
                  <span class="opacity-50">detected pitch:</span>
                  <span class={[
                    "inline-block w-3 h-3 rounded-full align-middle ml-1",
                    pitch_color_class(debug.detected_pitch)
                  ]} />
                  <span class="ml-1">{debug.detected_pitch}</span>
                </div>
              <% end %>
              <%= for {kind, value} <- Map.get(debug, :phashes, %{}), value do %>
                <% distance = phash_debug_distance(kind, value, card.card_print) %>
                <% is_winner = kind == winning_kind %>
                <% kind_threshold = phash_kind_threshold(kind) %>
                <div class={if is_winner, do: "font-semibold", else: ""}>
                  <span class="opacity-50">{if is_winner, do: "★", else: " "} phash:{kind}:</span> {value}
                  <%= if distance do %>
                    <span class={[
                      "ml-1",
                      cond do
                        distance < kind_threshold -> "text-success"
                        true -> "text-error"
                      end
                    ]}>
                      (distance: {distance} / threshold {kind_threshold})
                    </span>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <script :type={ColocatedHook} name=".DraggableCardPopout">
      import { isDebugEnabled } from "@/js/card_scanner/debug.js"

      export default {
        mounted() {
          const el = this.el
          const header = el.querySelector(".card-popout-header")
          const container = el.parentElement

          // Show debug section if debug mode is enabled
          const debugSection = el.querySelector(".card-popout-debug")
          if (debugSection && isDebugEnabled()) {
            debugSection.classList.remove("hidden")
          }

          const initX = parseFloat(el.dataset.x || "10")
          const initY = parseFloat(el.dataset.y || "10")

          // Clamp the popout's current position into the container's visible
          // area. Called at mount and again after the card image loads — the
          // image's height isn't known until then, so an early clamp would let
          // half the popout end up below the viewport once the image grows.
          const clampPosition = () => {
            const left = parseFloat(el.style.left) || initX
            const top = parseFloat(el.style.top) || initY
            const maxX = Math.max(0, container.clientWidth - el.offsetWidth)
            const maxY = Math.max(0, container.clientHeight - el.offsetHeight)
            el.style.left = Math.max(0, Math.min(left, maxX)) + "px"
            el.style.top = Math.max(0, Math.min(top, maxY)) + "px"
            this._currentLeft = el.style.left
            this._currentTop = el.style.top
          }

          clampPosition()

          // Re-clamp once the image's intrinsic size is known.
          const cardImg = el.querySelector("img")
          if (cardImg && !cardImg.complete) {
            cardImg.addEventListener("load", clampPosition, { once: true })
            cardImg.addEventListener("error", clampPosition, { once: true })
          }

          let offsetX = 0
          let offsetY = 0

          this.updated = () => {
            // LiveView re-renders reset the inline style to "left: 0; top: 0;".
            // Reapply the last known position so the popout doesn't jump on pitch switch.
            el.style.left = this._currentLeft
            el.style.top = this._currentTop
            // Re-apply debug visibility after re-render
            const dbg = el.querySelector(".card-popout-debug")
            if (dbg && isDebugEnabled()) dbg.classList.remove("hidden")
          }

          header.addEventListener("pointerdown", (e) => {
            if (e.target.closest("button, input")) return
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
