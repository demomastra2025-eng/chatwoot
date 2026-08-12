/* global axios */
import ApiClient from '../ApiClient';

class WhatsappChannel extends ApiClient {
  constructor() {
    super('whatsapp', { accountScoped: true });
  }

  createEmbeddedSignup(params) {
    return axios.post(`${this.baseUrl()}/whatsapp/authorization`, params);
  }

  logEmbeddedSignupSession(params) {
    return axios.post(
      `${this.baseUrl()}/whatsapp/authorization/session`,
      params
    );
  }

  reauthorizeWhatsApp({ inboxId, ...params }) {
    return axios.post(`${this.baseUrl()}/whatsapp/authorization`, {
      ...params,
      inbox_id: inboxId,
    });
  }

  registerPhoneNumber({ inboxId, verificationPin }) {
    return axios.post(`${this.baseUrl()}/whatsapp/phone_registration`, {
      inbox_id: inboxId,
      verification_pin: verificationPin,
    });
  }
}

export default new WhatsappChannel();
