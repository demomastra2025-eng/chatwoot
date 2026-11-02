/* global axios */
import CacheEnabledApiClient from './CacheEnabledApiClient';

class Inboxes extends CacheEnabledApiClient {
  constructor() {
    super('inboxes', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    return 'inbox';
  }

  getCampaigns(inboxId) {
    return axios.get(`${this.url}/${inboxId}/campaigns`);
  }

  deleteInboxAvatar(inboxId) {
    return axios.delete(`${this.url}/${inboxId}/avatar`);
  }

  syncTemplates(inboxId) {
    return axios.post(`${this.url}/${inboxId}/sync_templates`);
  }

  refreshWhatsappWebQr(inboxId, payload = {}) {
    return axios.post(
      `${this.url}/${inboxId}/refresh_whatsapp_web_qr`,
      payload
    );
  }

  reconnectWhatsappWeb(inboxId) {
    return axios.post(`${this.url}/${inboxId}/reconnect_whatsapp_web`);
  }

  reauthorizeWhatsappWeb(inboxId, { force = false } = {}) {
    const url = `${this.url}/${inboxId}/reauthorize_whatsapp_web`;

    return force ? axios.post(url, { force: true }) : axios.post(url);
  }

  disconnectWhatsappWeb(inboxId) {
    return axios.post(`${this.url}/${inboxId}/disconnect_whatsapp_web`);
  }

  getWhatsappWebDiagnostics(inboxId) {
    return axios.get(`${this.url}/${inboxId}/whatsapp_web_diagnostics`);
  }

  requestTelegramPersonalCode(inboxId) {
    return axios.post(`${this.url}/${inboxId}/telegram_personal_request_code`);
  }

  requestTelegramPersonalQr(inboxId) {
    return axios.post(`${this.url}/${inboxId}/telegram_personal_request_qr`);
  }

  verifyTelegramPersonalCode(inboxId, code) {
    return axios.post(`${this.url}/${inboxId}/telegram_personal_verify_code`, {
      code,
    });
  }

  verifyTelegramPersonalPassword(inboxId, password) {
    return axios.post(
      `${this.url}/${inboxId}/telegram_personal_verify_password`,
      {
        password,
      }
    );
  }

  reconnectTelegramPersonal(inboxId) {
    return axios.post(`${this.url}/${inboxId}/telegram_personal_reconnect`);
  }

  disconnectTelegramPersonal(inboxId) {
    return axios.post(`${this.url}/${inboxId}/telegram_personal_disconnect`);
  }

  getTelegramPersonalDiagnostics(inboxId) {
    return axios.get(`${this.url}/${inboxId}/telegram_personal_diagnostics`);
  }

  requestWeixinQr(inboxId) {
    return axios.post(`${this.url}/${inboxId}/weixin_request_qr`);
  }

  reconnectWeixin(inboxId) {
    return axios.post(`${this.url}/${inboxId}/weixin_reconnect`);
  }

  disconnectWeixin(inboxId) {
    return axios.post(`${this.url}/${inboxId}/weixin_disconnect`);
  }

  getWeixinDiagnostics(inboxId) {
    return axios.get(`${this.url}/${inboxId}/weixin_diagnostics`);
  }

  createCSATTemplate(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template`, {
      template,
    });
  }

  createWhatsAppTemplate(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/whatsapp_templates`, {
      template,
    });
  }

  deleteWhatsAppTemplate(inboxId, templateName) {
    return axios.delete(
      `${this.url}/${inboxId}/whatsapp_templates/${encodeURIComponent(
        templateName
      )}`
    );
  }

  updateWhatsAppTemplateVisibility(inboxId, templateName, visible) {
    return axios.patch(
      `${this.url}/${inboxId}/whatsapp_templates/${encodeURIComponent(
        templateName
      )}/visibility`,
      { visible_in_conversation_picker: visible }
    );
  }

  getCSATTemplateStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/csat_template`);
  }

  analyzeCSATTemplateUtility(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template/analyze`, {
      template,
    });
  }

  getWhatsAppFlows(inboxId) {
    return axios.get(`${this.url}/${inboxId}/whatsapp_flows`);
  }

  setupWhatsAppFlowsEncryption(inboxId, payload = {}) {
    return axios.post(
      `${this.url}/${inboxId}/whatsapp_flows/setup_encryption`,
      payload
    );
  }

  syncWhatsAppFlows(inboxId) {
    return axios.post(`${this.url}/${inboxId}/whatsapp_flows/sync`);
  }

  provisionWhatsAppBookingFlow(inboxId, whatsappFlow = {}) {
    return axios.post(
      `${this.url}/${inboxId}/whatsapp_flows/provision_booking`,
      {
        whatsapp_flow: whatsappFlow,
      }
    );
  }

  createWhatsAppFlow(inboxId, whatsappFlow) {
    return axios.post(`${this.url}/${inboxId}/whatsapp_flows`, {
      whatsapp_flow: whatsappFlow,
    });
  }

  publishWhatsAppFlow(inboxId, flowId) {
    return axios.post(
      `${this.url}/${inboxId}/whatsapp_flows/${encodeURIComponent(flowId)}/publish`
    );
  }

  deleteWhatsAppFlow(inboxId, flowId) {
    return axios.delete(
      `${this.url}/${inboxId}/whatsapp_flows/${encodeURIComponent(flowId)}`
    );
  }

  resetSecret(inboxId) {
    return axios.post(`${this.url}/${inboxId}/reset_secret`);
  }
}

export default new Inboxes();
