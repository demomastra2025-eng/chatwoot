/* global axios */
import ApiClient from '../ApiClient';

class KaspiPayAPI extends ApiClient {
  constructor() {
    super('integrations/kaspi_pay', { accountScoped: true });
  }

  get paymentsUrl() {
    return `${this.baseUrl()}/kaspi_pay/payments`;
  }

  getStatus({ verify = false } = {}) {
    return axios.get(`${this.url}/status`, {
      params: verify ? { verify: true } : {},
    });
  }

  sendOtp({ phoneNumber, appVersion, appBuild }) {
    return axios.post(`${this.url}/send_otp`, {
      phone_number: phoneNumber,
      app_version: appVersion || undefined,
      app_build: appBuild || undefined,
    });
  }

  verifyOtp({ processId, otp }) {
    return axios.post(`${this.url}/verify_otp`, {
      process_id: processId,
      otp,
    });
  }

  checkSession() {
    return axios.post(`${this.url}/check_session`);
  }

  updateSettings(payload) {
    return axios.patch(`${this.url}/update_settings`, payload);
  }

  disconnect() {
    return axios.delete(`${this.url}/disconnect`);
  }

  getPayments(params = {}) {
    return axios.get(this.paymentsUrl, { params });
  }

  getPayment(id) {
    return axios.get(`${this.paymentsUrl}/${id}`);
  }

  createPayment(payload) {
    return axios.post(this.paymentsUrl, payload);
  }

  refreshPayment(id) {
    return axios.post(`${this.paymentsUrl}/${id}/refresh`);
  }

  cancelPayment(id) {
    return axios.post(`${this.paymentsUrl}/${id}/cancel`);
  }

  refundPayment(id, { amount } = {}) {
    return axios.post(
      `${this.paymentsUrl}/${id}/refund`,
      amount ? { amount } : {}
    );
  }

  getClientInfo(phoneNumber, { conversationId } = {}) {
    return axios.post(`${this.paymentsUrl}/client_info`, {
      phone_number: phoneNumber,
      conversation_id: conversationId || undefined,
    });
  }
}

export default new KaspiPayAPI();
