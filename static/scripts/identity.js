import { mergePatch, getPath } from 'datastar'

function setIdentity() {
  let pk = localStorage.getItem('qckchs_pk')
  if (!pk) {
    pk = crypto.randomUUID().replaceAll('-', '')
    localStorage.setItem('qckchs_pk', pk)
  }

  const name = localStorage.getItem('qckchs_name') || ''
  mergePatch({ pk, name })
  document.cookie = `pk=${pk}; path=/; max-age=${60 * 60 * 24 * 365}; SameSite=Lax`

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      window.dispatchEvent(new CustomEvent('identity-ready'))
    })
  })
}

// Persist name changes to localStorage
document.addEventListener('datastar-signal-patch', (e) => {
  const name = getPath('name')
  if (name !== undefined) {
    localStorage.setItem('qckchs_name', name)
  }
})

if (document.readyState !== 'loading') {
  setIdentity()
} else {
  document.addEventListener('DOMContentLoaded', setIdentity)
}
