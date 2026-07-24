import {
  createMessageHandler,
  embeddedSignupSessionData,
  embeddedSignupFlowForEvent,
  EMBEDDED_SIGNUP_FLOW,
  getWhatsAppEmbeddedSignupConfigErrors,
  initWhatsAppEmbeddedSignup,
  initializeFacebook,
  isEmbeddedSignupErrorEvent,
  isEmbeddedSignupFinishEvent,
  isValidBusinessData,
} from './utils';

describe('WhatsApp Embedded Signup utils', () => {
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
});
