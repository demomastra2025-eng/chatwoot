/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingCalendarAPI extends ApiClient {
  constructor() {
    super('scheduling/calendar', { accountScoped: true });
  }

  show(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new SchedulingCalendarAPI();
