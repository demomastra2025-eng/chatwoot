import {
  createMessageHandler,
  getWhatsAppEmbeddedSignupConfigErrors,
  initWhatsAppEmbeddedSignup,
  isEmbeddedSignupErrorEvent,
  isEmbeddedSignupFinishEvent,
  isValidBusinessData,
} from './utils';

describe('WhatsApp Embedded Signup utils', () => {
  describe('isValidBusinessData', () => {
    it('requires business, WABA, and selected phone number ids from Meta', () => {
      expect(
        isValidBusinessData({
          business_id: 'business-1',
          waba_id: 'waba-1',
          phone_number_id: 'phone-1',
        })
      ).toBe(true);

      expect(
        isValidBusinessData({ business_id: 'business-1', waba_id: 'waba-1' })
      ).toBe(false);
      expect(
        isValidBusinessData({
          business_id: 'business-1',
          phone_number_id: 'phone-1',
        })
      ).toBe(false);
      expect(
        isValidBusinessData({ waba_id: 'waba-1', phone_number_id: 'phone-1' })
      ).toBe(false);
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
      expect(
        isEmbeddedSignupFinishEvent({
          event: 'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING',
        })
      ).toBe(true);
      expect(isEmbeddedSignupErrorEvent({ event: 'ERROR' })).toBe(true);
      expect(isEmbeddedSignupErrorEvent({ event: 'error' })).toBe(true);
      expect(isEmbeddedSignupFinishEvent({ event: 'CANCEL' })).toBe(false);
    });
  });

  describe('initWhatsAppEmbeddedSignup', () => {
    it('uses the official v4 code flow and setup extras', async () => {
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
        extras: { setup: {} },
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
