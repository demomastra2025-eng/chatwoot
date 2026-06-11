import {
  createMessageHandler,
  getWhatsAppEmbeddedSignupConfigErrors,
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
