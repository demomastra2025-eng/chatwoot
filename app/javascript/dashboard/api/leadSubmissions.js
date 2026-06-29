/* global axios */
import ApiClient from './ApiClient';

class LeadSubmissionsAPI extends ApiClient {
  constructor() {
    super('lead_submissions', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new LeadSubmissionsAPI();
