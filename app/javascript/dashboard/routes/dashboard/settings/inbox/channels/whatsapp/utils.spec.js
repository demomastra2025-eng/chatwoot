import {
  createMessageHandler,
  embeddedSignupSessionData,
  embeddedSignupFlowForEvent,
  EMBEDDED_SIGNUP_FLOW,
  getWhatsAppEmbeddedSignupConfigErrors,
  initWhatsAppEmbeddedSignup,
  initializeFacebook,
  loadFacebookSdk,
  isEmbeddedSignupErrorEvent,
  isEmbeddedSignupFinishEvent,
  isValidBusinessData,
  generateSignupNonce,
  savePendingSignup,
  loadPendingSignup,
  clearPendingSignup,
  isLikelyInAppBrowser,
  PENDING_SIGNUP_TTL_MS,
} from './utils';

describe('WhatsApp Embedded Signup utils', () => {
  describe('loadFacebookSdk', () => {
    afterEach(() => {
      document
        .querySelector(
          'script[src="https://connect.facebook.net/en_US/sdk.js"]'
        )
        ?.remove();
    });

    it('uses the anonymous CORS mode required by the official Meta SDK snippet', async () => {
      const loadPromise = loadFacebookSdk();
      const script = document.querySelector(
        'script[src="https://connect.facebook.net/en_US/sdk.js"]'
      );

      expect(script).not.toBeNull();
      expect(script.crossOrigin).toBe('anonymous');

      script.dispatchEvent(new Event('load'));
      await expect(loadPromise).resolves.toBe(script);
    });
  });

  describe('initializeFacebook', () => {
    it('uses the current Graph API v25 default when no runtime version is configured', async () => {
      window.FB = { init: vi.fn() };

      await initializeFacebook('app-1');

      expect(window.FB.init).toHaveBeenCalledWith(
        expect.objectContaining({ appId: 'app-1', version: 'v25.0' })
      );
    });
  });

  describe('isValidBusinessData', () => {
    it('accepts the official standard WABA-only completion payload', () => {
      expect(
        isValidBusinessData({
          business_id: 'business-1',
          waba_id: 'waba-1',
          phone_number_id: 'phone-1',
        })
      ).toBe(true);

      expect(
        isValidBusinessData({ business_id: 'business-1', waba_id: 'waba-1' })
      ).toBe(true);
      expect(
        isValidBusinessData({
          business_id: 'business-1',
          phone_number_id: 'phone-1',
        })
      ).toBe(false);
      expect(isValidBusinessData({ waba_id: 'waba-1' })).toBe(true);
      expect(isValidBusinessData({ business_id: 'business-1' })).toBe(false);
    });

    it('accepts the official coexistence completion payload with a WABA id', () => {
      expect(
        isValidBusinessData(
          { waba_id: 'waba-1' },
          EMBEDDED_SIGNUP_FLOW.COEXISTENCE
        )
      ).toBe(true);
    });
  });

  describe('getWhatsAppEmbeddedSignupConfigErrors', () => {
    it('reports missing public Meta signup config before opening the SDK popup', () => {
      expect(
        getWhatsAppEmbeddedSignupConfigErrors({
          whatsappAppId: 'none',
          whatsappConfigurationId: null,
        })
      ).toEqual(['WHATSAPP_APP_ID', 'WHATSAPP_CONFIGURATION_ID']);
    });

    it('accepts configured app and signup configuration ids', () => {
      expect(
        getWhatsAppEmbeddedSignupConfigErrors({
          whatsappAppId: 'app-1',
          whatsappConfigurationId: 'config-1',
        })
      ).toEqual([]);
    });
  });

  describe('embedded signup event helpers', () => {
    it('accepts supported finish and error event names', () => {
      expect(isEmbeddedSignupFinishEvent({ event: 'FINISH' })).toBe(true);
      expect(isEmbeddedSignupFinishEvent({ event: 'FINISH_ONLY_WABA' })).toBe(
        true
      );
      expect(
        isEmbeddedSignupFinishEvent({
          event: 'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING',
        })
      ).toBe(true);
      expect(isEmbeddedSignupErrorEvent({ event: 'ERROR' })).toBe(true);
      expect(isEmbeddedSignupErrorEvent({ event: 'error' })).toBe(true);
      expect(
        isEmbeddedSignupErrorEvent({
          event: 'CANCEL',
          data: { error_code: '123' },
        })
      ).toBe(true);
      expect(isEmbeddedSignupFinishEvent({ event: 'CANCEL' })).toBe(false);
      expect(
        embeddedSignupFlowForEvent({
          event: 'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING',
        })
      ).toBe(EMBEDDED_SIGNUP_FLOW.COEXISTENCE);
      expect(embeddedSignupFlowForEvent({ event: 'FINISH' })).toBe(
        EMBEDDED_SIGNUP_FLOW.STANDARD
      );
      expect(embeddedSignupFlowForEvent({ event: 'FINISH_ONLY_WABA' })).toBe(
        EMBEDDED_SIGNUP_FLOW.STANDARD
      );
    });

    it('extracts only non-secret session logging fields', () => {
      expect(
        embeddedSignupSessionData({
          event: 'CANCEL',
          version: 3,
          data: {
            error_code: '123',
            session_id: 'session-1',
            timestamp: '1700000000',
            access_token: 'must-not-leak',
          },
        })
      ).toEqual({
        event: 'CANCEL',
        version: 3,
        current_step: undefined,
        error_code: '123',
        session_id: 'session-1',
        event_timestamp: '1700000000',
        business_id: undefined,
        waba_id: undefined,
        phone_number_id: undefined,
      });
    });
  });

  describe('initWhatsAppEmbeddedSignup', () => {
    it('uses the official standard v4 code flow without coexistence extras', async () => {
      window.FB = {
        login: vi.fn(callback => {
          callback({ authResponse: { code: 'oauth-code' } });
        }),
      };

      await expect(initWhatsAppEmbeddedSignup('config-v4')).resolves.toBe(
        'oauth-code'
      );
      expect(window.FB.login).toHaveBeenCalledWith(expect.any(Function), {
        config_id: 'config-v4',
        response_type: 'code',
        override_default_response_type: true,
        extras: {},
      });
    });

    it('adds business-app onboarding extras only for coexistence', async () => {
      window.FB = {
        login: vi.fn(callback => {
          callback({ authResponse: { code: 'coexistence-code' } });
        }),
      };

      await initWhatsAppEmbeddedSignup(
        'config-v4',
        EMBEDDED_SIGNUP_FLOW.COEXISTENCE
      );

      expect(window.FB.login).toHaveBeenCalledWith(expect.any(Function), {
        config_id: 'config-v4',
        response_type: 'code',
        override_default_response_type: true,
        extras: {
          setup: {},
          featureType: 'whatsapp_business_app_onboarding',
          sessionInfoVersion: '3',
        },
      });
    });
  });

  describe('createMessageHandler', () => {
    it('accepts facebook.com and subdomain origins only', () => {
      const onEmbeddedSignupData = vi.fn();
      const handler = createMessageHandler(onEmbeddedSignupData);
      const data = JSON.stringify({
        type: 'WA_EMBEDDED_SIGNUP',
        event: 'FINISH',
      });

      handler({ origin: 'https://www.facebook.com', data });
      handler({ origin: 'https://business.facebook.com', data });
      handler({ origin: 'https://badfacebook.com', data });

      expect(onEmbeddedSignupData).toHaveBeenCalledTimes(2);
    });
  });

  describe('mobile-safe pending signup', () => {
    beforeEach(() => {
      window.localStorage.clear();
    });

    it('generates URL-safe nonces accepted by the server format', () => {
      const first = generateSignupNonce();
      const second = generateSignupNonce();

      expect(first).toMatch(/^[A-Za-z0-9_-]{32}$/);
      expect(second).not.toBe(first);
    });

    it('stores and restores a pending attempt per account and user', () => {
      const attempt = {
        nonce: generateSignupNonce(),
        flow: 'coexistence',
        startedAt: 1_000,
        codeSubmitted: false,
      };
      savePendingSignup(3, 7, attempt);

      expect(loadPendingSignup(3, 7, 2_000)).toEqual(attempt);
      expect(loadPendingSignup(3, 8, 2_000)).toBeNull();

      clearPendingSignup(3, 7);
      expect(loadPendingSignup(3, 7, 2_000)).toBeNull();
    });

    it('drops expired or malformed pending attempts', () => {
      savePendingSignup(3, 7, {
        nonce: 'n'.repeat(32),
        flow: 'standard',
        startedAt: 0,
      });
      expect(loadPendingSignup(3, 7, PENDING_SIGNUP_TTL_MS + 1)).toBeNull();
      expect(window.localStorage.length).toBe(0);

      savePendingSignup(3, 7, { nonce: 'n'.repeat(32), flow: 'other' });
      expect(loadPendingSignup(3, 7, 10)).toBeNull();

      window.localStorage.setItem(
        'onelink:whatsapp-embedded-signup:3:7',
        '{broken'
      );
      expect(loadPendingSignup(3, 7, 10)).toBeNull();
    });

    it('survives unavailable storage', () => {
      const getItem = vi
        .spyOn(Storage.prototype, 'getItem')
        .mockImplementation(() => {
          throw new Error('blocked');
        });
      const setItem = vi
        .spyOn(Storage.prototype, 'setItem')
        .mockImplementation(() => {
          throw new Error('blocked');
        });

      expect(() =>
        savePendingSignup(3, 7, { nonce: 'x', flow: 'standard' })
      ).not.toThrow();
      expect(loadPendingSignup(3, 7)).toBeNull();

      getItem.mockRestore();
      setItem.mockRestore();
    });

    it('recognises in-app browsers that cannot receive the Meta result', () => {
      expect(
        isLikelyInAppBrowser(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 330.0'
        )
      ).toBe(true);
      expect(
        isLikelyInAppBrowser(
          'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36'
        )
      ).toBe(true);
      expect(
        isLikelyInAppBrowser(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'
        )
      ).toBe(false);
      expect(
        isLikelyInAppBrowser(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0 Mobile/15E148 Safari/604.1'
        )
      ).toBe(false);
    });
  });
});
