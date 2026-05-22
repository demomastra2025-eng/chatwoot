/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class ContentPostsAPI extends ApiClient {
  constructor() {
    super('content/posts', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  create(data) {
    return axios.post(this.url, data);
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  updateStatus(id, status) {
    return axios.patch(`${this.url}/${id}/status`, { status });
  }

  missing(id) {
    return axios.get(`${this.url}/${id}/missing`);
  }
}

export default new ContentPostsAPI();
