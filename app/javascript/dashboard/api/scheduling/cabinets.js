/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingCabinetsAPI extends ApiClient {
  constructor() {
    super('scheduling/cabinets', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new SchedulingCabinetsAPI();
