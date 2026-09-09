export const runWhenDOMReady = (callback, documentRef = document) => {
  if (documentRef.readyState === 'loading') {
    documentRef.addEventListener('DOMContentLoaded', callback, { once: true });
    return;
  }

  callback();
};
