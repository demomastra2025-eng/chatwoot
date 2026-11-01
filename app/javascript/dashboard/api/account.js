/* global axios */
import ApiClient from './ApiClient';

class AccountAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true });
  }

  get currentAccountUrl() {
    return this.baseUrl();
  }

  get(accountId) {
    const url = accountId
      ? `${this.apiVersion}/accounts/${accountId}`
      : this.currentAccountUrl;
    return axios.get(url);
  }

  createAccount(data) {
    return axios.post(`${this.apiVersion}/accounts`, data);
  }

  update(id, { logo, ...accountAttributes }) {
    const url = id
      ? `${this.apiVersion}/accounts/${id}`
      : this.currentAccountUrl;
    if (!logo) {
      return axios.patch(url, accountAttributes);
    }

    const formData = new FormData();

    Object.entries(accountAttributes).forEach(([key, value]) => {
      if (value === undefined) return;

      if (Array.isArray(value)) {
        value.forEach(item => {
          formData.append(`${key}[]`, item);
        });
        return;
      }

      formData.append(key, value);
    });

    formData.append('logo', logo);

    return axios.patch(url, formData);
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
