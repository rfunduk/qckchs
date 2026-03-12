import { getPath, mergePatch } from 'datastar'

setInterval(() => {
  if (getPath('state') !== 'playing') { return }
  const side = getPath('turn') === 'white' ? 'white' : 'black'
  const val = getPath(`${side}.periods`)
  if (val <= 0) { return }
  const next = Math.round(val * 10 - 1) / 10
  mergePatch({ [side]: { periods: next } })
  if (next <= 0) {
    const turn = getPath('turn')
    const winner = turn === 'white' ? 'Black' : 'White'
    mergePatch({ state: 'resolved', result: `${winner} wins on time` })
    window.dispatchEvent(new CustomEvent('flag'))
  }
}, 100)
