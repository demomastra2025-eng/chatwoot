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

  createCSATTemplate(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template`, {
      template,
    });
  }

  getCSATTemplateStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/csat_template`);
  }
}

export default new Inboxes();
