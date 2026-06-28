/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmReportsAPI extends ApiClient {
  constructor() {
    super('crm/reports', { accountScoped: true });
  }

  deals(params = {}) {
    return axios.get(`${this.url}/deals`, { params });
  }

  managerEffectiveness(params = {}) {
    return axios.get(`${this.url}/manager_effectiveness`, { params });
  }

  funnels(params = {}) {
    return axios.get(`${this.url}/funnels`, { params });
  }
}

export default new CrmReportsAPI();
