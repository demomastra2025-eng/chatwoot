/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class ContentChannelsAPI extends ApiClient {
  constructor() {
    super('content/channels', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  oauthUrl(params) {
    return axios.get(`${this.url}/oauth_url`, { params });
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  findSlot(id) {
    return axios.get(`${this.url}/${id}/find_slot`);
  }
}

export default new ContentChannelsAPI();
