/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

// The services a specialist really performs, read from the visit history. Staff confirm or disable a pair.
class SchedulingResourceServiceStatsAPI extends ApiClient {
  constructor() {
    super('scheduling/resources', { accountScoped: true });
  }

  get(resourceId) {
    return axios.get(`${this.url}/${resourceId}/service_stats`);
  }

  update(resourceId, id, status) {
    return axios.patch(`${this.url}/${resourceId}/service_stats/${id}`, {
      status,
    });
  }
}

export default new SchedulingResourceServiceStatsAPI();
