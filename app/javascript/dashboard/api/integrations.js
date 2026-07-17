/* global axios */

import ApiClient from './ApiClient';

export const normalizeKaspiPayCashierPhone = phoneNumber => {
  const digits = String(phoneNumber || '').replace(/\D/g, '');
  if (digits.length === 11 && ['7', '8'].includes(digits[0])) {
    return digits.slice(1);
  }
  return digits;
};

class IntegrationsAPI extends ApiClient {
  constructor() {
    super('integrations/apps', { accountScoped: true });
  }

  connectSlack(code) {
    return axios.post(`${this.baseUrl()}/integrations/slack`, { code });
  }

  updateSlack({ referenceId }) {
    return axios.patch(`${this.baseUrl()}/integrations/slack`, {
      reference_id: referenceId,
    });
  }

  listAllSlackChannels() {
    return axios.get(`${this.baseUrl()}/integrations/slack/list_all_channels`);
  }

  delete(integrationId) {
    return axios.delete(`${this.baseUrl()}/integrations/${integrationId}`);
  }

  createHook(hookData) {
    return axios.post(`${this.baseUrl()}/integrations/hooks`, hookData);
  }

  updateHook(hookId, hookData) {
    return axios.patch(
      `${this.baseUrl()}/integrations/hooks/${hookId}`,
      hookData
    );
  }

  showHook(hookId) {
    return axios.get(`${this.baseUrl()}/integrations/hooks/${hookId}`);
  }

  deleteHook(hookId) {
    return axios.delete(`${this.baseUrl()}/integrations/hooks/${hookId}`);
  }

  runHookSync(hookId) {
    return axios.post(
      `${this.baseUrl()}/integrations/hooks/${hookId}/run_sync`
    );
  }

  connectShopify({ shopDomain }) {
    return axios.post(`${this.baseUrl()}/integrations/shopify/auth`, {
      shop_domain: shopDomain,
    });
  }

  initKaspiPayAuth() {
    return axios.post(`${this.baseUrl()}/integrations/kaspi_pay/auth/init`);
  }

  sendKaspiPayPhone({ processId, phoneNumber }) {
    return axios.post(
      `${this.baseUrl()}/integrations/kaspi_pay/auth/send_phone`,
      {
        process_id: processId,
        phone_number: normalizeKaspiPayCashierPhone(phoneNumber),
      }
    );
  }

  refreshKaspiPayAuth() {
    return axios.post(`${this.baseUrl()}/integrations/kaspi_pay/auth/refresh`);
  }

  verifyKaspiPayOtp({ processId, phoneNumber, otp, settings }) {
    return axios.post(
      `${this.baseUrl()}/integrations/kaspi_pay/auth/verify_otp`,
      {
        process_id: processId,
        phone_number: normalizeKaspiPayCashierPhone(phoneNumber),
        otp,
        settings,
      }
    );
  }
}

export default new IntegrationsAPI();
