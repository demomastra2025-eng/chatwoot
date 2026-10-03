/* global axios */

import ApiClient from './ApiClient';

class StorageAPI extends ApiClient {
  constructor() {
    super('storage', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  getHeavyFiles(params = {}) {
    return axios.get(`${this.url}/heavy_files`, { params });
  }

  refresh() {
    return axios.post(`${this.url}/refresh`);
  }
}

export default new StorageAPI();
