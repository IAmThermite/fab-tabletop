// Debug preview panel — shows the deskewed card and one preview per pHash region.

const DEBUG_KEY = "tabletop:card-debug"

export function isDebugEnabled() {
  return localStorage.getItem(DEBUG_KEY) === "true"
}

export function setDebugEnabled(enabled) {
  localStorage.setItem(DEBUG_KEY, enabled ? "true" : "false")
}

let _debugPanel = null

const HASH_KIND_COLORS = {
  art: "#8cf",
  art_flipped: "#c8f",
  art_left: "#fa6",
  art_right: "#fc6",
  full: "#9d9",
}

function addPreview(row, canvas, label, opts = {}) {
  const col = document.createElement("div")
  col.style.cssText = "display: flex; flex-direction: column; gap: 2px; border-left: 1px solid rgba(255,255,255,0.15); padding-left: 8px;"

  const lbl = document.createElement("span")
  lbl.style.cssText = "font-size: 10px; opacity: 0.7; font-weight: 600;"
  lbl.textContent = label
  col.appendChild(lbl)

  const img = document.createElement("img")
  img.src = canvas.toDataURL()
  img.style.cssText = `
    max-width: ${opts.maxWidth || 140}px; max-height: ${opts.maxHeight || 200}px;
    width: auto; height: auto;
    border: 1px solid rgba(255,255,255,0.2); border-radius: 3px;
  `
  col.appendChild(img)

  const size = document.createElement("span")
  size.style.cssText = "font-size: 9px; opacity: 0.5;"
  size.textContent = `${canvas.width}×${canvas.height}`
  col.appendChild(size)

  if (opts.hash != null) {
    const hashEl = document.createElement("span")
    hashEl.style.cssText = `font-size: 10px; font-weight: 600; color: ${opts.hashColor || "#8cf"}; font-family: monospace; word-break: break-all; max-width: ${opts.maxWidth || 140}px;`
    hashEl.textContent = opts.hash.toString()
    col.appendChild(hashEl)
  }

  row.appendChild(col)
}

export function showDebugPanel(result) {
  if (_debugPanel) _debugPanel.remove()

  _debugPanel = document.createElement("div")
  _debugPanel.style.cssText = `
    position: fixed; bottom: 8px; left: 8px; z-index: 9999;
    background: rgba(0,0,0,0.92); border: 1px solid rgba(255,255,255,0.3);
    border-radius: 8px; padding: 10px; max-width: 95vw;
    font-family: monospace; font-size: 11px; color: #fff;
    display: flex; flex-direction: column; gap: 6px;
    pointer-events: auto;
  `

  const closeBtn = document.createElement("button")
  closeBtn.textContent = "✕"
  closeBtn.style.cssText = `
    position: absolute; top: 4px; right: 8px;
    background: none; border: none; color: #fff; font-size: 14px;
    cursor: pointer; padding: 2px 4px;
  `
  closeBtn.onclick = () => { _debugPanel.remove(); _debugPanel = null }
  _debugPanel.appendChild(closeBtn)

  const title = document.createElement("div")
  title.textContent = "pHash Debug"
  title.style.cssText = "font-weight: bold; font-size: 12px; margin-bottom: 2px;"
  _debugPanel.appendChild(title)

  const row = document.createElement("div")
  row.style.cssText = "display: flex; gap: 8px; align-items: flex-start; flex-wrap: wrap;"

  // Deskewed card capture — what OpenCV produced.
  if (result.cardCanvas) {
    const angle = result.angle ? ` ${Math.abs(result.angle).toFixed(1)}°` : ""
    const layout = result.layout ? ` (${result.layout})` : ""
    addPreview(row, result.cardCanvas, `Deskewed card${layout}${angle}`, { maxWidth: 180, maxHeight: 240 })
  }

  // Title-bar capture — the region fed to OCR (vertical layout only).
  if (result.titleCanvas) {
    const ocrText = result.text ? ` "${result.text.slice(0, 40)}"` : ""
    addPreview(row, result.titleCanvas, `Title (OCR)${ocrText}`, { maxWidth: 220, maxHeight: 60 })
  }

  // One preview per pHash region.
  if (Array.isArray(result.phashes)) {
    for (const { kind, value, canvas } of result.phashes) {
      if (!canvas) continue
      addPreview(row, canvas, kind, {
        maxWidth: 140,
        maxHeight: 180,
        hash: value,
        hashColor: HASH_KIND_COLORS[kind] || "#fff",
      })
    }
  }

  _debugPanel.appendChild(row)

  // Detection signals (orientation, pitch, layout).
  const signals = document.createElement("div")
  signals.style.cssText = "margin-top: 4px; padding: 6px; background: rgba(255,255,255,0.06); border-radius: 4px; font-size: 10px; line-height: 1.6;"

  let html = `<div style="font-weight: 600; margin-bottom: 3px; opacity: 0.8;">Detection signals</div>`

  if (result.layout) {
    html += `<div style="margin-left: 8px;"><span style="color:#8cf">●</span> Layout: <b>${result.layout}</b></div>`
  }

  if (result.orientation) {
    const orientColor = result.orientation === "flipped" ? "#f96" : result.orientation === "uncertain" ? "#ff6" : "#6f6"
    html += `<div style="margin-left: 8px;"><span style="color:${orientColor}">●</span> Orientation: <b>${result.orientation}</b></div>`
  }

  if (result.detectedPitch) {
    const pitchColors = { 1: "#f66", 2: "#ff6", 3: "#6af" }
    html += `<div style="margin-left: 8px;"><span style="color:${pitchColors[result.detectedPitch] || "#fff"}">●</span> Pitch: <b>${result.detectedPitch}</b></div>`
  } else {
    html += `<div style="margin-left: 8px;"><span style="color:#888">●</span> Pitch: <span style="opacity:0.5">not detected</span></div>`
  }

  if (result.angle != null) {
    html += `<div style="margin-left: 8px;"><span style="color:#fff">●</span> Angle: <b>${Math.abs(result.angle).toFixed(1)}°</b></div>`
  }

  if (result.detectMethod) {
    html += `<div style="margin-left: 8px;"><span style="color:#fff">●</span> Detect method: <b>${result.detectMethod}</b></div>`
  }

  signals.innerHTML = html
  _debugPanel.appendChild(signals)

  document.body.appendChild(_debugPanel)
}

/**
 * Draw a quadrilateral outline over the detected card corners.
 * quad: array of 4 {x, y} points in the detect-region's canvas pixel space.
 * detectRegion: {sx, sy} offset of the detect region in canvas pixels.
 */
export function showCardQuad(canvasRect, quad, detectRegion, scaleX, scaleY, isFlipped) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
  svg.style.cssText = `
    position: fixed;
    left: ${canvasRect.left}px; top: ${canvasRect.top}px;
    width: ${canvasRect.width}px; height: ${canvasRect.height}px;
    pointer-events: none; z-index: 9998; overflow: visible;
  `

  const points = quad.map(({ x, y }) => {
    let cx = (x + detectRegion.sx) / scaleX
    let cy = (y + detectRegion.sy) / scaleY
    if (isFlipped) {
      cx = canvasRect.width - cx
      cy = canvasRect.height - cy
    }
    return `${cx},${cy}`
  }).join(" ")

  const poly = document.createElementNS("http://www.w3.org/2000/svg", "polygon")
  poly.setAttribute("points", points)
  poly.setAttribute("fill", "none")
  poly.setAttribute("stroke", "oklch(0.85 0.20 145)")
  poly.setAttribute("stroke-width", "2")
  poly.setAttribute("stroke-linejoin", "round")
  svg.appendChild(poly)

  const label = document.createElementNS("http://www.w3.org/2000/svg", "text")
  const firstPt = quad[0]
  let lx = (firstPt.x + detectRegion.sx) / scaleX
  const ly = (firstPt.y + detectRegion.sy) / scaleY - 6
  if (isFlipped) lx = canvasRect.width - lx
  label.setAttribute("x", lx)
  label.setAttribute("y", ly)
  label.setAttribute("fill", "oklch(0.85 0.20 145)")
  label.setAttribute("font-size", "10")
  label.setAttribute("font-weight", "600")
  label.setAttribute("font-family", "monospace")
  label.textContent = "Card"
  svg.appendChild(label)

  document.body.appendChild(svg)
  return svg
}

export function showBoundingBox(_container, canvasRect, cssX, cssY, cssW, cssH, isFlipped, color, label) {
  const box = document.createElement("div")
  let left = canvasRect.left + cssX
  let top = canvasRect.top + cssY
  if (isFlipped) {
    left = canvasRect.left + (canvasRect.width - cssX - cssW)
    top = canvasRect.top + (canvasRect.height - cssY - cssH)
  }
  box.style.cssText = `
    position: fixed;
    left: ${left}px; top: ${top}px;
    width: ${cssW}px; height: ${cssH}px;
    border: 2px solid ${color};
    border-radius: 4px;
    pointer-events: none;
    z-index: 9998;
    transition: opacity 1s ease-out;
  `
  if (label) {
    const tag = document.createElement("span")
    tag.textContent = label
    tag.style.cssText = `
      position: absolute; top: -18px; left: 0;
      font-size: 10px; line-height: 1;
      padding: 1px 4px; border-radius: 2px;
      background: ${color}; color: #000;
      white-space: nowrap; font-weight: 600;
    `
    box.appendChild(tag)
  }
  document.body.appendChild(box)
  return box
}
