import { getPath } from 'datastar'

const SPEED = "80ms"

let draggingSq = null
let clone = null
let originEl = null
let offsetX = 0
let offsetY = 0
let hoverEl = null
let skipNextAnimation = false

// --- Move animation (FLIP technique) ---

let pieceSnapshot = null
let animPending = false

function snapshotPieces() {
  const snap = new Map()
  for (const sq of document.querySelectorAll('#board [data-sq]')) {
    const piece = sq.dataset.piece
    if (piece) {
      const el = sq.querySelector('img')
      if (el) {
        snap.set(sq.dataset.sq, { piece, rect: el.getBoundingClientRect() })
      }
    }
  }
  return snap
}

function animateBoardChange() {
  const oldSnap = pieceSnapshot
  pieceSnapshot = snapshotPieces()

  if (!oldSnap) { return }
  if (skipNextAnimation) {
    skipNextAnimation = false
    return
  }

  // Classify changes between old and new snapshots
  let emptied = null  // had piece, now empty
  let appeared = null // was empty, now has piece
  let changed = null  // had piece, now different piece

  for (const [sq, data] of oldSnap) {
    const cur = pieceSnapshot.get(sq)
    if (!cur) {
      emptied = { sq, rect: data.rect }
    } else if (cur.piece !== data.piece) {
      changed = { sq, rect: data.rect }
    }
  }
  for (const [sq] of pieceSnapshot) {
    if (!oldSnap.has(sq)) {
      appeared = sq
    }
  }

  let fromRect = null
  let toEl = null

  if (emptied && appeared) {
    // Normal move or promotion: piece left one square, appeared at another
    fromRect = emptied.rect
    toEl = document.querySelector(`#board [data-sq="${appeared}"] img`)
  } else if (emptied && changed) {
    // Capture: piece left source, replaced captured piece at destination
    fromRect = emptied.rect
    toEl = document.querySelector(`#board [data-sq="${changed.sq}"] img`)
  } else if (appeared && changed) {
    // Backward capture: piece returns to source, captured piece reappears
    fromRect = changed.rect
    toEl = document.querySelector(`#board [data-sq="${appeared}"] img`)
  }

  if (!fromRect || !toEl) { return }

  const toRect = toEl.getBoundingClientRect()
  const dx = fromRect.left - toRect.left
  const dy = fromRect.top - toRect.top

  // FLIP: place at old position, then animate to new
  toEl.style.transition = 'none'
  toEl.style.transform = `translate(${dx}px, ${dy}px)`
  void toEl.offsetWidth // force reflow
  toEl.style.transition = `transform ${SPEED} ease-out`
  toEl.style.transform = ''
  toEl.addEventListener('transitionend', () => {
    toEl.style.transition = ''
  }, { once: true })
}

// Observe the board's parent so we survive outer-mode morphs that replace #board.
// Debounce via microtask so multiple mutation records from a single morph
// trigger only one animation.
function initBoardObserver() {
  const board = document.getElementById('board')
  if (!board || !board.parentNode) { return }

  pieceSnapshot = snapshotPieces()

  new MutationObserver(() => {
    if (!document.getElementById('board')) { return }
    if (animPending) { return }
    animPending = true
    queueMicrotask(() => {
      animPending = false
      animateBoardChange()
    })
  }).observe(board.parentNode, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-piece'] })
}

initBoardObserver()

// --- Drag and drop ---

document.addEventListener('pointerdown', (e) => {
  const sq = e.target.closest('#board [data-sq]')
  if (!sq || sq.dataset.piece === '') { return }

  const turn = getPath('turn')
  const color = getPath('color')
  if (!color || turn !== color) { return }

  e.preventDefault()
  draggingSq = parseInt(sq.dataset.sq)
  originEl = sq

  // Highlight valid targets
  const targetsStr = sq.dataset.targets
  if (targetsStr) {
    const targets = targetsStr.split(',').map(Number)
    for (const idx of targets) {
      const el = document.querySelector(`#board [data-sq="${idx}"]`)
      if (el) { el.classList.add('valid-target') }
    }
  }

  const piece = sq.querySelector('img')
  const rect = piece.getBoundingClientRect()
  offsetX = e.clientX - rect.left
  offsetY = e.clientY - rect.top

  clone = piece.cloneNode(true)
  clone.classList.add('drag-clone')
  clone.style.width = rect.width + 'px'
  clone.style.height = rect.height + 'px'
  clone.style.transform = `translate(${e.clientX - offsetX}px, ${e.clientY - offsetY}px)`
  document.body.appendChild(clone)

  sq.classList.add('dragging')
})

document.addEventListener('pointermove', (e) => {
  if (!clone) { return }
  clone.style.transform = `translate(${e.clientX - offsetX}px, ${e.clientY - offsetY}px)`

  const el = document.elementFromPoint(e.clientX, e.clientY)
  const sq = el?.closest('#board [data-sq]')

  if (hoverEl && hoverEl !== sq) {
    hoverEl.classList.remove('hover-target')
    hoverEl = null
  }

  if (sq && sq.classList.contains('valid-target')) {
    sq.classList.add('hover-target')
    hoverEl = sq
  }
})

document.addEventListener('pointerup', (e) => {
  if (draggingSq === null) { return }

  if (clone) {
    clone.remove()
    clone = null
  }
  if (originEl) {
    originEl.classList.remove('dragging')
    originEl = null
  }

  const target = document.elementFromPoint(e.clientX, e.clientY)
  const targetSq = target?.closest('[data-sq]')

  if (targetSq && targetSq.classList.contains('valid-target')) {
    const toSq = parseInt(targetSq.dataset.sq)
    const fromSq = draggingSq
    if (toSq !== fromSq) {
      // Optimistically move the piece in the DOM
      const fromEl = document.querySelector(`#board [data-sq="${fromSq}"]`)
      const toEl = document.querySelector(`#board [data-sq="${toSq}"]`)
      if (fromEl && toEl) {
        const pieceImg = fromEl.querySelector('img')
        const capturedImg = toEl.querySelector('img')
        if (capturedImg) { capturedImg.remove() }
        if (pieceImg) { toEl.appendChild(pieceImg) }
        toEl.dataset.piece = fromEl.dataset.piece
        fromEl.dataset.piece = ''
        // Clear all targets since it's no longer our turn
        for (const sq of document.querySelectorAll('#board [data-sq]')) {
          sq.dataset.targets = ''
        }
      }
      skipNextAnimation = true
      requestAnimationFrame(() => {
        window.dispatchEvent(
          new CustomEvent(
            'make-move',
            { detail: { from: fromSq, to: toSq } }
          )
        )
      })
    }
  }

  document.querySelectorAll('.valid-target, .hover-target').forEach(el => {
    el.classList.remove('valid-target', 'hover-target')
  })

  hoverEl = null
  draggingSq = null
})
