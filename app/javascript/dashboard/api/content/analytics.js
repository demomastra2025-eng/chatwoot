/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class ContentAnalyticsAPI extends ApiClient {
  constructor() {
    super('content/analytics', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new ContentAnalyticsAPI();
