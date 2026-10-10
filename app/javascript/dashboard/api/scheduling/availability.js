/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingAvailabilityAPI extends ApiClient {
  constructor() {
    super('scheduling/availability', { accountScoped: true });
  }

  show(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new SchedulingAvailabilityAPI();
