/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingExceptionsAPI extends ApiClient {
  constructor() {
    super('scheduling', { accountScoped: true });
  }

  getHolidays(params = {}) {
    return axios.get(`${this.url}/holidays`, { params });
  }

  createHoliday(data) {
    return axios.post(`${this.url}/holidays`, data);
  }

  updateHoliday(id, data) {
    return axios.patch(`${this.url}/holidays/${id}`, data);
  }

  deleteHoliday(id) {
    return axios.delete(`${this.url}/holidays/${id}`);
  }

  getWorkdayOverrides(params = {}) {
    return axios.get(`${this.url}/workday_overrides`, { params });
  }

  createWorkdayOverride(data) {
    return axios.post(`${this.url}/workday_overrides`, data);
  }

  updateWorkdayOverride(id, data) {
    return axios.patch(`${this.url}/workday_overrides/${id}`, data);
  }

  deleteWorkdayOverride(id) {
    return axios.delete(`${this.url}/workday_overrides/${id}`);
  }

  getTimeOffs(params = {}) {
    return axios.get(`${this.url}/time_offs`, { params });
  }

  createTimeOff(data) {
    return axios.post(`${this.url}/time_offs`, data);
  }

  updateTimeOff(id, data) {
    return axios.patch(`${this.url}/time_offs/${id}`, data);
  }

  deleteTimeOff(id) {
    return axios.delete(`${this.url}/time_offs/${id}`);
  }
}

export default new SchedulingExceptionsAPI();
