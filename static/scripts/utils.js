function copyToClipboard(event, content) {
	navigator.clipboard.writeText(content)
	const beforeContent = event.target.textContent
	event.target.textContent = 'Copied!'
	setTimeout(() => event.target.textContent = beforeContent, 2000)
}

function maybeSetPkAndReload(newPk) {
	const k = newPk.trim()
	if (k.length === 32) { setPk(k) }
	window.location.href = "/profile"
}

function setPk(pk) {
	localStorage.setItem('qckchs_pk', pk)
	document.cookie = `pk=${pk}; path=/; max-age=${60 * 60 * 24 * 365}; SameSite=Lax`
}

function clearPkAndReload() {
	localStorage.removeItem('qckchs_pk')
	document.cookie = `pk=; path=/; max-age=0; SameSite=Lax`
	window.location.href = "/profile"
}
