/* global axios */
import ApiClient from './ApiClient';

class BulkActionsAPI extends ApiClient {
  constructor() {
    super('bulk_actions', { accountScoped: true });
  }

  show(id) {
    return axios.get(`${this.baseUrl()}/bulk_action_runs/${id}`);
  }
}

export default new BulkActionsAPI();
