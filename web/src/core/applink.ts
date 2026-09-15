/**
 * Hand the current view to the native app.
 *
 * Universal Links are the right mechanism: an https link opens the app
 * directly, before this page renders, with no button and nothing to click.
 * They need a signed app carrying an `associated-domains` entitlement, and
 * the app is ad-hoc signed today, so the custom scheme is the only thing that
 * can reach it. `.well-known/apple-app-site-association` is already served,
 * so the moment the app is signed this stops being the path anyone takes.
 *
 * Deliberately a button rather than an automatic redirect. Navigating to an
 * unhandled custom scheme raises a browser error dialog for everyone who does
 * not have the app — which is most visitors — and it would fire on every
 * shared link someone opens. A button that the people with the app can press
 * costs nobody else anything.
 */

/** Apple platforms only; nothing else can have the app. */
function isApple(): boolean {
  const ua = navigator.userAgent
  // iPadOS reports itself as a Mac, and is caught by the same test.
  return /Macintosh|iPhone|iPad|iPod/.test(ua) && !/Android/.test(ua)
}

export function initAppLink() {
  const el = document.getElementById('openApp')
  if (!el) return
  if (!isApple()) return
  el.hidden = false
  el.addEventListener('click', () => {
    // The scheme carries the same query string the web reads, so the app
    // lands on this exact view rather than its own last one.
    window.location.href = `vegvisr://open${window.location.search}`
  })
}
