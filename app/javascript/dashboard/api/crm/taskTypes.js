/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmTaskTypesAPI extends ApiClient {
  constructor() {
    super('crm/task_types', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new CrmTaskTypesAPI();
