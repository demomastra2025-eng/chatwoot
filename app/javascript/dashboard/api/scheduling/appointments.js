/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingAppointmentsAPI extends ApiClient {
  constructor() {
    super('scheduling/appointments', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  notifications(id) {
    return axios.get(`${this.url}/${id}/notifications`);
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

  cancel(id, payload = {}) {
    return axios.post(`${this.url}/${id}/cancel`, payload);
  }
}

export default new SchedulingAppointmentsAPI();
