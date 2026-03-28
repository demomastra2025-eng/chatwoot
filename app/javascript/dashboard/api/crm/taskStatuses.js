/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmTaskStatusesAPI extends ApiClient {
  constructor() {
    super('crm/task_statuses', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  deleteTaskStatus(taskStatusId) {
    return this.delete(taskStatusId);
  }
}

export default new CrmTaskStatusesAPI();
