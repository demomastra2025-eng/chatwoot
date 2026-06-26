/* global axios */

import ApiClient from './ApiClient';

class TouchPlansAPI extends ApiClient {
  constructor() {
    super('touch_plans', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  archive(id) {
    return axios.post(`${this.url}/${id}/archive`);
  }

  apply(id, payload) {
    return axios.post(`${this.url}/${id}/apply`, payload);
  }
}

export default new TouchPlansAPI();
