const FAVICON_BLINK_INTERVAL = 1000;
const DEFAULT_BLINK_HOLDER = 'notification';

let faviconBlinkTimer = null;
// Who asked for the blinking. A named holder stops only its own request, so
// one feature (a ringing call) cannot cancel a blink another still needs.
const blinkHolders = new Set();
let isBadgeVisible = false;
// An unread badge shown before the blinking began, which comes back when a
// named holder stops the blinking.
let badgeShownBeforeBlink = false;
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

export const stopFaviconBlinking = holder => {
  if (typeof holder === 'string') {
    if (!blinkHolders.delete(holder) || blinkHolders.size) return;
  } else {
    blinkHolders.clear();
    badgeShownBeforeBlink = false;
  }
  if (faviconBlinkTimer) {
    clearInterval(faviconBlinkTimer);
    faviconBlinkTimer = null;
  }
  if (badgeShownBeforeBlink) {
    showBadgeOnFavicon();
  } else {
    restoreFavicon();
  }
};

export const initFaviconSwitcher = () => {
  if (isFaviconSwitcherInitialized) return;

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') stopFaviconBlinking();
  });
  isFaviconSwitcherInitialized = true;
};

export const startFaviconBlinking = (holder = DEFAULT_BLINK_HOLDER) => {
  initFaviconSwitcher();
  if (document.visibilityState !== 'hidden') return;

  blinkHolders.add(holder);
  if (faviconBlinkTimer) return;

  badgeShownBeforeBlink = isBadgeVisible;
  showBadgeOnFavicon();
  faviconBlinkTimer = setInterval(() => {
    if (isBadgeVisible) {
      restoreFavicon();
    } else {
      showBadgeOnFavicon();
    }
  }, FAVICON_BLINK_INTERVAL);
};
