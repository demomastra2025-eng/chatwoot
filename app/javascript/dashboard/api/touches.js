/* global axios */

import ApiClient from './ApiClient';

class TouchesAPI extends ApiClient {
  constructor() {
    super('touches', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  approve(id) {
    return axios.post(`${this.url}/${id}/approve`);
  }

  cancel(id, payload = {}) {
    return axios.post(`${this.url}/${id}/cancel`, payload);
  }
}

export default new TouchesAPI();
