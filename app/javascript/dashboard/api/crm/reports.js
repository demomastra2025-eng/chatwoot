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

  stageDurations(params = {}) {
    return axios.get(`${this.url}/stage_durations`, { params });
  }

  taskResults(params = {}) {
    return axios.get(`${this.url}/task_results`, { params });
  }

  dealsWithoutNextAction(params = {}) {
    return axios.get(`${this.url}/deals_without_next_action`, { params });
  }
}

export default new CrmReportsAPI();
