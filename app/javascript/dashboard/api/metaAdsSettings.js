/* global axios */
import ApiClient from './ApiClient';

class MetaAdsSettingsAPI extends ApiClient {
  constructor() {
    super('meta_ads_settings', { accountScoped: true });
  }

  updateSettings(data) {
    return axios.put(this.url, data);
  }
}

export default new MetaAdsSettingsAPI();
