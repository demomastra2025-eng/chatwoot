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

  getAgentBot(inboxId) {
    return axios.get(`${this.url}/${inboxId}/agent_bot`);
  }

  setAgentBot(inboxId, botId) {
    return axios.post(`${this.url}/${inboxId}/set_agent_bot`, {
      agent_bot: botId,
    });
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

  disconnectWhatsappWeb(inboxId) {
    return axios.post(`${this.url}/${inboxId}/disconnect_whatsapp_web`);
  }

  repairWhatsappWeb(inboxId) {
    return axios.post(`${this.url}/${inboxId}/repair_whatsapp_web`);
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

  historySyncTelegramPersonal(inboxId, payload = {}) {
    return axios.post(
      `${this.url}/${inboxId}/telegram_personal_history_sync`,
      payload
    );
  }

  contactsSyncTelegramPersonal(inboxId, payload = {}) {
    return axios.post(
      `${this.url}/${inboxId}/telegram_personal_contacts_sync`,
      payload
    );
  }

  disconnectTelegramPersonal(inboxId) {
    return axios.post(`${this.url}/${inboxId}/telegram_personal_disconnect`);
  }

  getTelegramPersonalDiagnostics(inboxId) {
    return axios.get(`${this.url}/${inboxId}/telegram_personal_diagnostics`);
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

  getCSATTemplateStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/csat_template`);
  }

  analyzeCSATTemplateUtility(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template/analyze`, {
      template,
    });
  }
}

export default new Inboxes();
