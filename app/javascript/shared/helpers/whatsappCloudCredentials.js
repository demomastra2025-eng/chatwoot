export const generateWebhookVerifyToken = (cryptoProvider = window.crypto) => {
  const bytes = cryptoProvider.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
};

const storageKey = inboxId => `whatsapp-webhook-verify-token:${inboxId}`;

export const storeOneTimeWebhookVerifyToken = (
  inboxId,
  token,
  storage = window.sessionStorage
) => {
  if (inboxId && token) storage.setItem(storageKey(inboxId), token);
};

export const getOneTimeWebhookVerifyToken = (
  inboxId,
  storage = window.sessionStorage
) => storage.getItem(storageKey(inboxId)) || '';

export const clearOneTimeWebhookVerifyToken = (
  inboxId,
  storage = window.sessionStorage
) => storage.removeItem(storageKey(inboxId));
