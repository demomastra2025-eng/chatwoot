export const createEvent = ({ eventName, data = null }) => {
  let event;
  if (typeof window.CustomEvent === 'function') {
    event = new CustomEvent(eventName, { detail: data });
  } else {
    event = document.createEvent('CustomEvent');
    event.initCustomEvent(eventName, false, false, data);
  }
  return event;
};

export const dispatchWindowEvent = ({ eventName, data }) => {
  // Keep the iframe wire protocol stable for cached SDKs. Public events use
  // OneLink and retain the previous event name for existing website listeners.
  const publicName = String(eventName).replace(/^chatwoot:/, 'onelink:');
  const legacyName = publicName.replace(/^onelink:/, 'chatwoot:');
  const eventNames = [...new Set([publicName, legacyName])];
  eventNames.forEach(name => {
    window.dispatchEvent(createEvent({ eventName: name, data }));
  });
};
