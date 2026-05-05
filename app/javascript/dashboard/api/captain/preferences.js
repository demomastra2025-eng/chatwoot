/* global axios */
import ApiClient from '../ApiClient';

class CaptainPreferences extends ApiClient {
  constructor() {
    super('captain/preferences', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  updatePreferences(data) {
    return axios.put(this.url, data);
  }

  refreshOpenRouterModels() {
    return axios.post(`${this.url}/refresh_openrouter_models`);
  }
}

export default new CaptainPreferences();
