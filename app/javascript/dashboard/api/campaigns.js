/* global axios */
import ApiClient from './ApiClient';

class CampaignsAPI extends ApiClient {
  constructor() {
    super('campaigns', { accountScoped: true });
  }

  getAnalytics(id) {
    return axios.get(`${this.url}/${id}/analytics`);
  }
}

export default new CampaignsAPI();
