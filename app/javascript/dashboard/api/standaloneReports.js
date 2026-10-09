/* global axios */
import ApiClient from './ApiClient';

class StandaloneReportsAPI extends ApiClient {
  constructor() {
    super('reports', { accountScoped: true, apiVersion: 'v1' });
  }

  getCalls({ fromDate, toDate } = {}) {
    return axios.get(`${this.url}/calls`, {
      params: { from_date: fromDate, to_date: toDate },
    });
  }

  getLeads({ fromDate, toDate } = {}) {
    return axios.get(`${this.url}/leads`, {
      params: { from_date: fromDate, to_date: toDate },
    });
  }
}

export default new StandaloneReportsAPI();
