/* global axios */
import ApiClient from './ApiClient';

class BulkActionsAPI extends ApiClient {
  constructor() {
    super('bulk_actions', { accountScoped: true });
  }

  create(payload) {
    const url = payload.selection ? `${this.url}/v2` : this.url;
    return axios.post(url, payload);
  }

  show(id) {
    return axios.get(`${this.baseUrl()}/bulk_action_runs/${id}`);
  }
}

export default new BulkActionsAPI();
