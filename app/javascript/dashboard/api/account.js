/* global axios */
import ApiClient from './ApiClient';

class AccountAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true });
  }

  get currentAccountUrl() {
    return this.baseUrl();
  }

  get() {
    return axios.get(this.currentAccountUrl);
  }

  createAccount(data) {
    return axios.post(`${this.apiVersion}/accounts`, data);
  }

  update(_id, { logo, ...accountAttributes }) {
    if (!logo) {
      return axios.patch(this.currentAccountUrl, accountAttributes);
    }

    const formData = new FormData();

    Object.entries(accountAttributes).forEach(([key, value]) => {
      if (value === undefined) return;

      formData.append(key, value);
    });

    formData.append('logo', logo);

    return axios.patch(this.currentAccountUrl, formData);
  }

  deleteLogo() {
    return axios.delete(`${this.currentAccountUrl}/logo`);
  }

  delete() {
    return axios.delete(this.currentAccountUrl);
  }

  async getCacheKeys() {
    const response = await axios.get(
      `/api/v1/accounts/${this.accountIdFromRoute}/cache_keys`
    );
    return response.data.cache_keys;
  }
}

export default new AccountAPI();
