/* global axios */

import ApiClient from './ApiClient';

class Agents extends ApiClient {
  constructor() {
    super('agents', { accountScoped: true });
  }

  bulkInvite({ emails }) {
    return axios.post(`${this.url}/bulk_create`, {
      emails,
    });
  }

  delete(id, params) {
    if (params && Object.keys(params).length > 0) {
      return axios.delete(`${this.url}/${id}`, { params });
    }
    return super.delete(id);
  }
}

export default new Agents();
