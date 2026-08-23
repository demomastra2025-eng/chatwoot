const FAVICON_BLINK_INTERVAL = 1000;

let faviconBlinkTimer = null;
let isBadgeVisible = false;
let isFaviconSwitcherInitialized = false;
const originalFaviconHrefs = new WeakMap();

const favicons = () => document.querySelectorAll('.favicon, link[rel~="icon"]');

const badgeFaviconPath = favicon => {
  const declaredSize = favicon.getAttribute('sizes')?.split(/\s+/)[0];
  const size = ['16x16', '32x32', '96x96'].includes(declaredSize)
    ? declaredSize
    : '32x32';
  return `/favicon-badge-${size}.png`;
};

export const showBadgeOnFavicon = () => {
  favicons().forEach(favicon => {
    if (!originalFaviconHrefs.has(favicon)) {
      originalFaviconHrefs.set(favicon, favicon.getAttribute('href'));
    }
    favicon.href = badgeFaviconPath(favicon);
  });
  isBadgeVisible = true;
};

export const restoreFavicon = () => {
  favicons().forEach(favicon => {
    if (!originalFaviconHrefs.has(favicon)) return;

    const originalHref = originalFaviconHrefs.get(favicon);
    const badgeHref = badgeFaviconPath(favicon);
    if (favicon.getAttribute('href') === badgeHref) {
      if (originalHref === null) {
        favicon.removeAttribute('href');
      } else {
        favicon.setAttribute('href', originalHref);
      }
    }
    originalFaviconHrefs.delete(favicon);
  });
  isBadgeVisible = false;
};

export const stopFaviconBlinking = () => {
  if (faviconBlinkTimer) {
    clearInterval(faviconBlinkTimer);
    faviconBlinkTimer = null;
  }
  restoreFavicon();
};

export const initFaviconSwitcher = () => {
  if (isFaviconSwitcherInitialized) return;

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') stopFaviconBlinking();
  });
  isFaviconSwitcherInitialized = true;
};

export const startFaviconBlinking = () => {
  initFaviconSwitcher();
  if (document.visibilityState !== 'hidden' || faviconBlinkTimer) return;

  showBadgeOnFavicon();
  faviconBlinkTimer = setInterval(() => {
    if (isBadgeVisible) {
      restoreFavicon();
    } else {
      showBadgeOnFavicon();
    }
  }, FAVICON_BLINK_INTERVAL);
};
