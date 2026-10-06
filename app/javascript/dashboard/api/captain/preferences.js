/* global axios */
import ApiClient from '../ApiClient';

class CaptainPreferences extends ApiClient {
  constructor() {
    super('captain/preferences', { accountScoped: true });
  }

  get(params) {
    return axios.get(this.url, { params });
  }

  updatePreferences(data) {
    return axios.put(this.url, data);
  }
}

export default new CaptainPreferences();
