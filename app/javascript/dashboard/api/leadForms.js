/* global axios */
import ApiClient from './ApiClient';

class LeadFormsAPI extends ApiClient {
  constructor() {
    super('lead_forms', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new LeadFormsAPI();
