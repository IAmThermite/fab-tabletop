// Debug preview panel — shows raw, grayscale, and threshold images + OCR result

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

  addPreview(result.rawCanvas, "Raw capture", null, null)
  addPreview(result.grayCanvas, "Sharpened grayscale", result.grayConfidence, result.grayText)
  if (result.upGrayCanvas) {
    addPreview(result.upGrayCanvas, "Upscaled grayscale", result.upGrayConfidence, result.upGrayText)
  }
  if (result.sharpThreshCanvas) {
    addPreview(result.sharpThreshCanvas, "Sharp + threshold", result.sharpThreshConfidence, result.sharpThreshText)
  }
  addPreview(result.processedCanvas, "Adaptive threshold", result.threshConfidence, result.threshText)

  // Show full card capture if available
  if (result.cardCanvas) {
    const cardCol = document.createElement("div")
    cardCol.style.cssText = "display: flex; flex-direction: column; gap: 2px; border-left: 1px solid rgba(255,255,255,0.15); padding-left: 8px;"
    const cardLbl = document.createElement("span")
    cardLbl.style.cssText = "font-size: 10px; opacity: 0.7;"
    cardLbl.textContent = result.rotation ? `Card (rotated ${result.rotation}\u00b0)` : "Card capture"
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
    artLbl.textContent = result.rotation ? `Art (rotated ${result.rotation}\u00b0)` : "Art region"
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

  _debugPanel.appendChild(row)

  const resultEl = document.createElement("div")
  resultEl.style.cssText = "margin-top: 4px; padding: 4px 6px; background: rgba(255,255,255,0.1); border-radius: 4px;"
  const rotationLabel = result.rotation ? ` | rotation: ${result.rotation}\u00b0` : ""
  const hashLabel = result.artHash ? ` | pHash: ${result.artHash}` : ""
  resultEl.innerHTML = `
    <div style="opacity: 0.7; font-size: 10px;">Best result (confidence: ${confidence ?? "?"}${rotationLabel}${hashLabel})</div>
    <div style="font-size: 13px; font-weight: bold; margin-top: 2px;">${ocrText || "<em style='opacity:0.5'>no text detected</em>"}</div>
  `
  _debugPanel.appendChild(resultEl)

  // Append to body so LiveView patches don't remove it
  document.body.appendChild(_debugPanel)
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
