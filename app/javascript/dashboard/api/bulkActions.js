/* global axios */
import ApiClient from './ApiClient';

class BulkActionsAPI extends ApiClient {
  constructor() {
    super('bulk_actions', { accountScoped: true });
  }

  captureContext() {
    return {
      accountId: String(this.accountIdFromRoute || ''),
      baseUrl: this.baseUrl(),
    };
  }

  isContextCurrent(context) {
    return (
      !context ||
      String(this.accountIdFromRoute || '') === String(context.accountId || '')
    );
  }

  create(data, context = null) {
    const baseUrl = context?.baseUrl || this.baseUrl();
    return axios.post(`${baseUrl}/${this.resource}`, data);
  }

  show(id, context = null, options = {}) {
    const baseUrl = context?.baseUrl || this.baseUrl();
    const url = `${baseUrl}/bulk_action_runs/${id}`;
    return Object.keys(options).length
      ? axios.get(url, options)
      : axios.get(url);
  }

  findDeletion(requestKey, context) {
    return axios.get(`${context.baseUrl}/bulk_action_runs`, {
      params: { request_key: requestKey },
      timeout: 5000,
    });
  }

  selectAll(type, filters) {
    return axios.post(`${this.url}/selection`, { type, filters });
  }
}

export default new BulkActionsAPI();
