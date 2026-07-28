/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingProviderCommandsAPI extends ApiClient {
  constructor() {
    super('scheduling/provider_commands', { accountScoped: true });
  }

  get(id) {
    return axios.get(`${this.url}/${id}`);
  }

  create(data) {
    return axios.post(this.url, data);
  }

  confirm(id) {
    return axios.post(`${this.url}/${id}/confirm`);
  }
}

export default new SchedulingProviderCommandsAPI();
