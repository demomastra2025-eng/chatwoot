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

  // The nonce stays in the JSON body so it never lands in URLs or access logs.
  registerEmbeddedSignupAttempt({ signupNonce, signupType }) {
    return axios.post(`${this.baseUrl()}/whatsapp/embedded_signup_attempt`, {
      signup_nonce: signupNonce,
      signup_type: signupType,
    });
  }

  getEmbeddedSignupAttemptStatus({ signupNonce }) {
    return axios.post(
      `${this.baseUrl()}/whatsapp/embedded_signup_attempt/status`,
      { signup_nonce: signupNonce }
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
