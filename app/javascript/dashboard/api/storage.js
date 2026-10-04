/* global axios */
import ApiClient from './ApiClient';

class StorageAPI extends ApiClient {
  constructor() {
    super('storage', { accountScoped: true });
  }

  getStorage() {
    return axios.get(this.url);
  }

  getHeavyFiles(params = {}) {
    return axios.get(`${this.url}/heavy_files`, { params });
  }

  refresh() {
    return axios.post(`${this.url}/refresh`);
  }

  previewCleanup(params = {}) {
    return axios.post(`${this.url}/preview_cleanup`, params);
  }

  moveToTrash(params = {}) {
    return axios.post(`${this.url}/move_to_trash`, params);
  }

  getTrash(params = {}) {
    return axios.get(`${this.url}/trash`, { params });
  }

  restoreTrash(params = {}) {
    return axios.post(`${this.url}/restore_trash`, params);
  }

  emptyTrash(params = {}) {
    return axios.delete(`${this.url}/empty_trash`, { params });
  }
}

export default new StorageAPI();
