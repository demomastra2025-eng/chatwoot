import { loadScript } from 'dashboard/helper/DOMHelpers';

export const loadFacebookSdk = async () => {
  return loadScript('https://connect.facebook.net/en_US/sdk.js', {
    async: true,
    defer: true,
    crossOrigin: 'anonymous',
  });
};

export const initializeFacebook = (appId, apiVersion) => {
  const version = apiVersion || 'v25.0';
  return new Promise(resolve => {
    const init = () => {
      window.FB.init({
        appId,
        autoLogAppEvents: true,
        xfbml: true,
        version,
      });
      resolve();
    };

    if (window.FB) {
      init();
    } else {
      window.fbAsyncInit = init;
    }
  });
};

export const EMBEDDED_SIGNUP_FLOW = {
  STANDARD: 'standard',
  COEXISTENCE: 'coexistence',
};

export const embeddedSignupFlowForEvent = data => {
  return data?.event === 'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING'
    ? EMBEDDED_SIGNUP_FLOW.COEXISTENCE
    : EMBEDDED_SIGNUP_FLOW.STANDARD;
};

export const isValidBusinessData = businessData => {
  return !!businessData?.waba_id;
};

const EMBEDDED_SIGNUP_FINISH_EVENTS = [
  'FINISH',
  'FINISH_ONLY_WABA',
  'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING',
];

export const isEmbeddedSignupFinishEvent = data => {
  return EMBEDDED_SIGNUP_FINISH_EVENTS.includes(data?.event);
};

export const isEmbeddedSignupErrorEvent = data => {
  return (
    ['ERROR', 'error'].includes(data?.event) ||
    (data?.event === 'CANCEL' && !!data?.data?.error_code)
  );
};

export const embeddedSignupSessionData = data => {
  const details = data?.data || {};
  return {
    event: data?.event,
    version: data?.version,
    current_step: details.current_step,
    error_code: details.error_code,
    session_id: details.session_id,
    event_timestamp: details.timestamp,
    business_id: details.business_id,
    waba_id: details.waba_id,
    phone_number_id: details.phone_number_id,
  };
};

export const getWhatsAppEmbeddedSignupConfigErrors = config => {
  const missingConfig = [];
  if (!config?.whatsappAppId || config.whatsappAppId === 'none') {
    missingConfig.push('WHATSAPP_APP_ID');
  }
  if (
    !config?.whatsappConfigurationId ||
    config.whatsappConfigurationId === 'none'
  ) {
    missingConfig.push('WHATSAPP_CONFIGURATION_ID');
  }
  return missingConfig;
};

const isAllowedFacebookOrigin = origin => {
  try {
    const { hostname } = new URL(origin);
    return hostname === 'facebook.com' || hostname.endsWith('.facebook.com');
  } catch {
    return false;
  }
};

export const createMessageHandler = onEmbeddedSignupData => {
  return event => {
    if (!isAllowedFacebookOrigin(event.origin)) return;

    try {
      let data;
      if (typeof event.data === 'string') {
        data = JSON.parse(event.data);
      } else if (typeof event.data === 'object' && event.data !== null) {
        data = event.data;
      } else {
        return;
      }

      if (data.type === 'WA_EMBEDDED_SIGNUP') {
        onEmbeddedSignupData(data);
      }
    } catch {
      // Ignore non-JSON or irrelevant messages
    }
  };
};

export const initWhatsAppEmbeddedSignup = (
  configId,
  flow = EMBEDDED_SIGNUP_FLOW.STANDARD
) => {
  return new Promise((resolve, reject) => {
    const extras =
      flow === EMBEDDED_SIGNUP_FLOW.COEXISTENCE
        ? {
            setup: {},
            featureType: 'whatsapp_business_app_onboarding',
            sessionInfoVersion: '3',
          }
        : {};

    window.FB.login(
      response => {
        if (response.authResponse && response.authResponse.code) {
          resolve(response.authResponse.code);
        } else if (response.error) {
          reject(new Error(response.error));
        } else {
          reject(new Error('Login cancelled'));
        }
      },
      {
        config_id: configId,
        response_type: 'code',
        override_default_response_type: true,
        extras,
      }
    );
  });
};

// --- Mobile-safe completion -------------------------------------------------
// On phones Meta opens as a separate tab. The dashboard tab can be suspended or
// reloaded meanwhile, and Meta's WA_EMBEDDED_SIGNUP message is often never
// delivered even though FB.login returns the auth code. The helpers below keep
// a small pending-attempt marker (no secrets) so a resumed/reloaded tab can
// ask the server for the outcome instead of spinning forever.

export const PENDING_SIGNUP_TTL_MS = 30 * 60 * 1000;
const PENDING_SIGNUP_STORAGE_PREFIX = 'onelink:whatsapp-embedded-signup:';

export const generateSignupNonce = (cryptoImpl = window.crypto) => {
  const bytes = new Uint8Array(24);
  cryptoImpl.getRandomValues(bytes);
  let binary = '';
  bytes.forEach(byte => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
};

const pendingSignupStorageKey = (accountId, userId) =>
  `${PENDING_SIGNUP_STORAGE_PREFIX}${accountId || 'account'}:${userId || 'user'}`;

const safeStorage = () => {
  try {
    return window.localStorage || null;
  } catch {
    return null;
  }
};

export const savePendingSignup = (accountId, userId, attempt) => {
  try {
    safeStorage()?.setItem(
      pendingSignupStorageKey(accountId, userId),
      JSON.stringify(attempt)
    );
  } catch {
    // Storage can be unavailable (private mode, quota); resume is best effort.
  }
};

export const clearPendingSignup = (accountId, userId) => {
  try {
    safeStorage()?.removeItem(pendingSignupStorageKey(accountId, userId));
  } catch {
    // Ignore unavailable storage.
  }
};

export const loadPendingSignup = (accountId, userId, now = Date.now()) => {
  let attempt = null;
  try {
    const raw = safeStorage()?.getItem(
      pendingSignupStorageKey(accountId, userId)
    );
    attempt = raw ? JSON.parse(raw) : null;
  } catch {
    attempt = null;
  }

  const valid =
    attempt &&
    typeof attempt.nonce === 'string' &&
    Object.values(EMBEDDED_SIGNUP_FLOW).includes(attempt.flow) &&
    Number.isFinite(attempt.startedAt) &&
    now - attempt.startedAt >= 0 &&
    now - attempt.startedAt < PENDING_SIGNUP_TTL_MS;

  if (!valid) {
    if (attempt) clearPendingSignup(accountId, userId);
    return null;
  }
  return attempt;
};

// Facebook/Instagram/Messenger/LINE/WhatsApp and similar in-app browsers do not
// keep a popup connected to the page that opened it, so Meta cannot report back.
export const isLikelyInAppBrowser = (userAgent = navigator.userAgent || '') =>
  /FBAN|FBAV|FB_IAB|FBIOS|Instagram|Messenger|Line\/|WhatsApp|Snapchat|MicroMessenger|; wv\)/i.test(
    userAgent
  );

export const setupFacebookSdk = async (appId, apiVersion) => {
  const version = apiVersion || 'v25.0';
  await loadFacebookSdk();
  await initializeFacebook(appId, version);
};
