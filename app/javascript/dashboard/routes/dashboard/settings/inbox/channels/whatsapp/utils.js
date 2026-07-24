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

export const setupFacebookSdk = async (appId, apiVersion) => {
  const version = apiVersion || 'v25.0';
  await loadFacebookSdk();
  await initializeFacebook(appId, version);
};
