// Debug preview panel — shows raw, grayscale, and threshold images + OCR result

const DEBUG_KEY = "tabletop:card-debug"

export function isDebugEnabled() {
  return localStorage.getItem(DEBUG_KEY) === "true"
}

export function setDebugEnabled(enabled) {
  localStorage.setItem(DEBUG_KEY, enabled ? "true" : "false")
}

let _debugPanel = null

export function showDebugPanel(result, ocrText, confidence) {
  if (_debugPanel) _debugPanel.remove()

  _debugPanel = document.createElement("div")
  _debugPanel.style.cssText = `
    position: fixed; bottom: 8px; left: 8px; z-index: 9999;
    background: rgba(0,0,0,0.92); border: 1px solid rgba(255,255,255,0.3);
    border-radius: 8px; padding: 10px; max-width: 90vw;
    font-family: monospace; font-size: 11px; color: #fff;
    display: flex; flex-direction: column; gap: 6px;
    pointer-events: auto;
  `

  const closeBtn = document.createElement("button")
  closeBtn.textContent = "\u2715"
  closeBtn.style.cssText = `
    position: absolute; top: 4px; right: 8px;
    background: none; border: none; color: #fff; font-size: 14px;
    cursor: pointer; padding: 2px 4px;
  `
  closeBtn.onclick = () => { _debugPanel.remove(); _debugPanel = null }
  _debugPanel.appendChild(closeBtn)

  const title = document.createElement("div")
  title.textContent = "OCR Debug"
  title.style.cssText = "font-weight: bold; font-size: 12px; margin-bottom: 2px;"
  _debugPanel.appendChild(title)

  const row = document.createElement("div")
  row.style.cssText = "display: flex; gap: 8px; align-items: flex-start;"

  const addPreview = (canvas, label, conf, text) => {
    const col = document.createElement("div")
    col.style.cssText = "display: flex; flex-direction: column; gap: 2px;"
    const lbl = document.createElement("span")
    lbl.style.cssText = "font-size: 10px; opacity: 0.7;"
    lbl.textContent = label
    col.appendChild(lbl)
    const img = document.createElement("img")
    img.src = canvas.toDataURL()
    img.style.cssText = `
      max-width: 300px; height: auto; border: 1px solid rgba(255,255,255,0.2);
      image-rendering: pixelated; border-radius: 3px;
    `
    col.appendChild(img)
    const info = document.createElement("span")
    info.style.cssText = "font-size: 9px; opacity: 0.5;"
    info.textContent = `${canvas.width}\u00d7${canvas.height}`
    col.appendChild(info)
    if (conf != null) {
      const confEl = document.createElement("span")
      confEl.style.cssText = `font-size: 10px; font-weight: 600; color: ${conf >= 65 ? "#6f6" : conf >= 40 ? "#ff6" : "#f66"};`
      confEl.textContent = `conf: ${Math.round(conf)}`
      col.appendChild(confEl)
    }
    if (text != null) {
      const textEl = document.createElement("span")
      textEl.style.cssText = "font-size: 10px; opacity: 0.8; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
      textEl.textContent = `"${text}"`
      col.appendChild(textEl)
    }
    row.appendChild(col)
  }

  if (result.rawCanvas) addPreview(result.rawCanvas, "Raw capture", null, null)
  if (result.grayCanvas) addPreview(result.grayCanvas, "Sharpened grayscale", result.grayConfidence, result.grayText)
  if (result.upGrayCanvas) addPreview(result.upGrayCanvas, "Upscaled grayscale", result.upGrayConfidence, result.upGrayText)
  if (result.sharpThreshCanvas) addPreview(result.sharpThreshCanvas, "Sharp + threshold", result.sharpThreshConfidence, result.sharpThreshText)
  if (result.processedCanvas) addPreview(result.processedCanvas, "Adaptive threshold", result.threshConfidence, result.threshText)

  // Show full card capture if available
  if (result.cardCanvas) {
    const cardCol = document.createElement("div")
    cardCol.style.cssText = "display: flex; flex-direction: column; gap: 2px; border-left: 1px solid rgba(255,255,255,0.15); padding-left: 8px;"
    const cardLbl = document.createElement("span")
    cardLbl.style.cssText = "font-size: 10px; opacity: 0.7;"
    cardLbl.textContent = result.angle ? `Card (deskewed ${Math.abs(result.angle).toFixed(1)}\u00b0)` : "Card capture"
    cardCol.appendChild(cardLbl)
    const cardImg = document.createElement("img")
    cardImg.src = result.cardCanvas.toDataURL()
    cardImg.style.cssText = `
      max-width: 150px; max-height: 200px; width: auto; height: auto;
      border: 1px solid rgba(255,255,255,0.2); border-radius: 3px;
    `
    cardCol.appendChild(cardImg)
    const cardSize = document.createElement("span")
    cardSize.style.cssText = "font-size: 9px; opacity: 0.5;"
    cardSize.textContent = `${result.cardCanvas.width}\u00d7${result.cardCanvas.height}`
    cardCol.appendChild(cardSize)
    row.appendChild(cardCol)
  }

  // Show art region and pHash if available
  if (result.artCanvas) {
    const artCol = document.createElement("div")
    artCol.style.cssText = "display: flex; flex-direction: column; gap: 2px; border-left: 1px solid rgba(255,255,255,0.15); padding-left: 8px;"
    const artLbl = document.createElement("span")
    artLbl.style.cssText = "font-size: 10px; opacity: 0.7;"
    artLbl.textContent = "Art region"
    artCol.appendChild(artLbl)
    const artImg = document.createElement("img")
    artImg.src = result.artCanvas.toDataURL()
    artImg.style.cssText = `
      max-width: 120px; max-height: 120px; width: auto; height: auto;
      border: 1px solid rgba(255,255,255,0.2); border-radius: 3px;
    `
    artCol.appendChild(artImg)
    const artSize = document.createElement("span")
    artSize.style.cssText = "font-size: 9px; opacity: 0.5;"
    artSize.textContent = `${result.artCanvas.width}\u00d7${result.artCanvas.height}`
    artCol.appendChild(artSize)
    if (result.artHash) {
      const hashEl = document.createElement("span")
      hashEl.style.cssText = "font-size: 10px; font-weight: 600; color: #8cf; font-family: monospace; letter-spacing: 1px;"
      hashEl.textContent = result.artHash
      artCol.appendChild(hashEl)
    }
    row.appendChild(artCol)
  }

  // Show flipped art region and pHash if available (uncertain orientation)
  if (result.artCanvasFlipped) {
    const flipCol = document.createElement("div")
    flipCol.style.cssText = "display: flex; flex-direction: column; gap: 2px; border-left: 1px solid rgba(255,255,255,0.15); padding-left: 8px;"
    const flipLbl = document.createElement("span")
    flipLbl.style.cssText = "font-size: 10px; opacity: 0.7;"
    flipLbl.textContent = "Art region (flipped)"
    flipCol.appendChild(flipLbl)
    const flipImg = document.createElement("img")
    flipImg.src = result.artCanvasFlipped.toDataURL()
    flipImg.style.cssText = `
      max-width: 120px; max-height: 120px; width: auto; height: auto;
      border: 1px solid rgba(255,255,255,0.2); border-radius: 3px;
    `
    flipCol.appendChild(flipImg)
    const flipSize = document.createElement("span")
    flipSize.style.cssText = "font-size: 9px; opacity: 0.5;"
    flipSize.textContent = `${result.artCanvasFlipped.width}\u00d7${result.artCanvasFlipped.height}`
    flipCol.appendChild(flipSize)
    if (result.artHashFlipped) {
      const flipHashEl = document.createElement("span")
      flipHashEl.style.cssText = "font-size: 10px; font-weight: 600; color: #c8f; font-family: monospace; letter-spacing: 1px;"
      flipHashEl.textContent = result.artHashFlipped
      flipCol.appendChild(flipHashEl)
    }
    row.appendChild(flipCol)
  }

  _debugPanel.appendChild(row)

  const resultEl = document.createElement("div")
  resultEl.style.cssText = "margin-top: 4px; padding: 4px 6px; background: rgba(255,255,255,0.1); border-radius: 4px;"
  const methodLabels = { "title_bar": "Title bar OCR", "card_art": "Card art pHash", "title_bar + card_art": "Title bar + Card art", "title_bar (flipped)": "Title bar OCR (flipped)" }
  const methodLabel = result.detectMethod ? ` | method: ${methodLabels[result.detectMethod] || result.detectMethod}` : ""
  const rotationLabel = result.angle ? ` | angle: ${Math.abs(result.angle).toFixed(1)}\u00b0` : ""
  const orientationLabel = result.orientation ? ` | orient: ${result.orientation}` : ""
  const hashLabel = result.artHash ? ` | pHash: ${result.artHash}` : ""
  const hashFlippedLabel = result.artHashFlipped ? ` | pHash\u2191\u2193: ${result.artHashFlipped}` : ""
  resultEl.innerHTML = `
    <div style="opacity: 0.7; font-size: 10px;">Best result (confidence: ${confidence ?? "?"}${methodLabel}${rotationLabel}${orientationLabel}${hashLabel}${hashFlippedLabel})</div>
    <div style="font-size: 13px; font-weight: bold; margin-top: 2px;">${ocrText || "<em style='opacity:0.5'>no text detected</em>"}</div>
  `
  _debugPanel.appendChild(resultEl)

  // Decision list: show all OCR candidates, filtering, and detection signals
  const listEl = document.createElement("div")
  listEl.style.cssText = "margin-top: 4px; padding: 6px; background: rgba(255,255,255,0.06); border-radius: 4px; font-size: 10px; line-height: 1.6;"

  const allCandidates = [
    { label: "gray", text: result.grayText, confidence: result.grayConfidence },
    { label: "upGray", text: result.upGrayText, confidence: result.upGrayConfidence },
    { label: "sharpThresh", text: result.sharpThreshText, confidence: result.sharpThreshConfidence },
    { label: "thresh", text: result.threshText, confidence: result.threshConfidence },
  ]

  let html = `<div style="font-weight: 600; margin-bottom: 3px; opacity: 0.8;">Decision Logic</div>`

  // OCR candidates
  html += `<div style="opacity: 0.6; margin-bottom: 2px;">OCR candidates (threshold: conf&gt;40, 3+ alpha):</div>`
  for (const c of allCandidates) {
    const alphaLen = (c.text || "").replace(/[^a-zA-Z]/g, "").length
    const passed = (c.confidence || 0) > 40 && c.text && alphaLen >= 3
    const color = passed ? "#6f6" : "#f66"
    const icon = passed ? "\u2713" : "\u2717"
    const confStr = c.confidence != null ? Math.round(c.confidence) : "?"
    html += `<div style="margin-left: 8px;"><span style="color:${color}">${icon}</span> <b>${c.label}</b>: "${c.text || ""}" <span style="opacity:0.6">(conf: ${confStr}, alpha: ${alphaLen})</span></div>`
  }

  // Detection signals
  html += `<div style="opacity: 0.6; margin-top: 4px; margin-bottom: 2px;">Detection signals:</div>`

  if (result.orientation) {
    const orientColor = result.orientation === "flipped" ? "#f96" : result.orientation === "uncertain" ? "#ff6" : "#6f6"
    html += `<div style="margin-left: 8px;"><span style="color:${orientColor}">\u25cf</span> Orientation: <b>${result.orientation}</b></div>`
  }

  if (result.detectedPitch) {
    const pitchColors = { 1: "#f66", 2: "#ff6", 3: "#6af" }
    html += `<div style="margin-left: 8px;"><span style="color:${pitchColors[result.detectedPitch] || "#fff"}">\u25cf</span> Pitch: <b>${result.detectedPitch}</b></div>`
  } else {
    html += `<div style="margin-left: 8px;"><span style="color:#888">\u25cf</span> Pitch: <span style="opacity:0.5">not detected</span></div>`
  }

  if (result.artHash != null) {
    html += `<div style="margin-left: 8px;"><span style="color:#8cf">\u25cf</span> pHash: <span style="font-family:monospace">${result.artHash}</span></div>`
  }
  if (result.artHashFlipped != null) {
    html += `<div style="margin-left: 8px;"><span style="color:#c8f">\u25cf</span> pHash (flipped): <span style="font-family:monospace">${result.artHashFlipped}</span></div>`
  }

  // Sent payload summary
  const sent = allCandidates.filter(c => (c.confidence || 0) > 40 && c.text && (c.text).replace(/[^a-zA-Z]/g, "").length >= 3)
  html += `<div style="opacity: 0.6; margin-top: 4px; margin-bottom: 2px;">Payload sent to server:</div>`
  html += `<div style="margin-left: 8px;">OCR candidates: <b>${sent.length}</b> of ${allCandidates.length} passed filter</div>`
  html += `<div style="margin-left: 8px;">pHash: <b>${result.artHash != null ? "yes" : "no"}</b>${result.artHashFlipped != null ? " + flipped" : ""}</div>`
  html += `<div style="margin-left: 8px;">Detect method: <b>${result.detectMethod || "none"}</b></div>`

  listEl.innerHTML = html
  _debugPanel.appendChild(listEl)

  // Append to body so LiveView patches don't remove it
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
    // Translate from detect-region coords back to full canvas pixel coords
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
  // Append to body so LiveView patches don't remove them
  document.body.appendChild(box)
  return box
}
