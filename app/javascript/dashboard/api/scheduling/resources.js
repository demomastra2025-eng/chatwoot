/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingResourcesAPI extends ApiClient {
  constructor() {
    super('scheduling/resources', { accountScoped: true });
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

  getWorkRules(resourceId) {
    return axios.get(`${this.url}/${resourceId}/work_rules`);
  }

  updateWorkRules(resourceId, workRules) {
    return axios.patch(`${this.url}/${resourceId}/work_rules`, {
      work_rules: workRules,
    });
  }

  getBreakRules(resourceId) {
    return axios.get(`${this.url}/${resourceId}/break_rules`);
  }

  updateBreakRules(resourceId, breakRules) {
    return axios.patch(`${this.url}/${resourceId}/break_rules`, {
      break_rules: breakRules,
    });
  }
}

export default new SchedulingResourcesAPI();
