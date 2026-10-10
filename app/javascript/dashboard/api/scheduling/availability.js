/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingAvailabilityAPI extends ApiClient {
  constructor() {
    super('scheduling/availability', { accountScoped: true });
  }

  show(params = {}, options = {}) {
    return axios.get(this.url, { ...options, params });
  }
}

export default new SchedulingAvailabilityAPI();
