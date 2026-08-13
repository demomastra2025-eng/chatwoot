/* global axios */
import ApiClient from './ApiClient';

class CampaignsAPI extends ApiClient {
  constructor() {
    super('campaigns', { accountScoped: true });
  }

  preview(data) {
    return axios.post(`${this.url}/preview`, data);
  }

  importAudience({ file, inboxId, defaultCountry }) {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('inbox_id', inboxId);
    formData.append('default_country', defaultCountry);
    return axios.post(`${this.baseUrl()}/campaign_audience_imports`, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  getAudienceImport(id) {
    return axios.get(`${this.baseUrl()}/campaign_audience_imports/${id}`);
  }

  getAnalytics(id) {
    return axios.get(`${this.url}/${id}/analytics`);
  }

  retryFailed(id) {
    return axios.post(`${this.url}/${id}/retry_failed`);
  }

  cancel(id) {
    return axios.post(`${this.url}/${id}/cancel`);
  }

  restart(id) {
    return axios.post(`${this.url}/${id}/restart`);
  }

  resume(id) {
    return axios.post(`${this.url}/${id}/resume`);
  }
}

export default new CampaignsAPI();
