/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingProductsAPI extends ApiClient {
  constructor() {
    super('scheduling/products', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  create(data) {
    return axios.post(this.url, data);
  }

  update(id, data) {
    return axios.patch(`${this.url}/${id}`, data);
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  getMoyskladStatus() {
    return axios.get(`${this.url}/moysklad_status`);
  }

  saveMoyskladConfig(data) {
    return axios.put(`${this.url}/moysklad_config`, data);
  }

  syncMoysklad(data = {}) {
    return axios.post(`${this.url}/sync_moysklad`, data);
  }
}

export default new SchedulingProductsAPI();
