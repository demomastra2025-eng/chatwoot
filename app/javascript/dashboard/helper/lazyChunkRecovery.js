import { emitter } from 'shared/helpers/mitt';

export const STALE_CHUNK_REFRESH_EVENT = 'onelink:before-stale-chunk-refresh';

const RECOVERY_NOTICE_TTL_MS = 60_000;
const RECOVERY_NOTICE_MAX_ENTRIES = 20;

const assetFingerprint = event => {
  const message = event?.payload?.message || event?.detail?.message || '';
  const assetUrl = message.match(
    /(?:https?:\/\/|\/)[^\s"'<>]+\.(?:m?js|css)(?:\?[^\s"'<>]*)?/i
  )?.[0];

  if (assetUrl) return assetUrl.split(/[?#]/, 1)[0];
  return message.split('\n', 1)[0] || 'vite:preloadError';
};

export const installLazyChunkRecovery = ({
  windowRef = window,
  now = Date.now,
  emit = (...args) => emitter.emit(...args),
} = {}) => {
  const lastNotices = new Map();

  const onPreloadError = event => {
    event.preventDefault();

    const timestamp = now();
    for (const [fingerprint, lastSeen] of lastNotices) {
      if (timestamp - lastSeen >= RECOVERY_NOTICE_TTL_MS) {
        lastNotices.delete(fingerprint);
      }
    }

    const fingerprint = assetFingerprint(event);
    const lastSeen = lastNotices.get(fingerprint);
    if (lastSeen !== undefined && timestamp - lastSeen < RECOVERY_NOTICE_TTL_MS) {
      return;
    }

    if (lastNotices.size >= RECOVERY_NOTICE_MAX_ENTRIES) {
      const oldestFingerprint = lastNotices.keys().next().value;
      lastNotices.delete(oldestFingerprint);
    }
    lastNotices.set(fingerprint, timestamp);

    emit('newToastMessage', {
      message: 'GENERAL_SETTINGS.STALE_CHUNK_RECOVERY',
      action: {
        type: 'callback',
        message: 'GENERAL_SETTINGS.STALE_CHUNK_REFRESH',
        usei18n: true,
        duration: 10_000,
        onClick: () => {
          windowRef.dispatchEvent(new Event(STALE_CHUNK_REFRESH_EVENT));
          windowRef.location.reload();
        },
      },
    });
  };

  windowRef.addEventListener('vite:preloadError', onPreloadError);

  return () => {
    windowRef.removeEventListener('vite:preloadError', onPreloadError);
  };
};
