/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class ContentConnectionAPI extends ApiClient {
  constructor() {
    super('content/connection', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  update(data) {
    return axios.patch(this.url, data);
  }

  delete() {
    return axios.delete(this.url);
  }

  test() {
    return axios.post(`${this.url}/test`);
  }
}

export default new ContentConnectionAPI();
