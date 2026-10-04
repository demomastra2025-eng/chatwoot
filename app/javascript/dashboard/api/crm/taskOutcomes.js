/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmTaskOutcomesAPI extends ApiClient {
  constructor() {
    super('crm/task_outcomes', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new CrmTaskOutcomesAPI();
