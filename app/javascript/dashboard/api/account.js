/* global axios */
import ApiClient from './ApiClient';

class AccountAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true });
    this.pendingUpdates = new Map();
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

  update(id, attributes) {
    const url = id
      ? `${this.apiVersion}/accounts/${id}`
      : this.currentAccountUrl;
    const previous = this.pendingUpdates.get(url);
    const patch = () => AccountAPI.patchAccount(url, attributes);
    const request = previous
      ? previous.catch(() => undefined).then(patch)
      : patch();
    this.pendingUpdates.set(url, request);
    const clear = () => {
      if (this.pendingUpdates.get(url) === request)
        this.pendingUpdates.delete(url);
    };
    request.then(clear, clear);
    return request;
  }

  static patchAccount(url, { logo, ...accountAttributes }) {
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
