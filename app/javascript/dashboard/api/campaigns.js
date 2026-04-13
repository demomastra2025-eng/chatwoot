/* global axios */
import ApiClient from './ApiClient';

class CampaignsAPI extends ApiClient {
  constructor() {
    super('campaigns', { accountScoped: true });
  }

  preview(data) {
    return axios.post(`${this.url}/preview`, data);
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
