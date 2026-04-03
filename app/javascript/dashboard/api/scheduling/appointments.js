/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingAppointmentsAPI extends ApiClient {
  constructor() {
    super('scheduling/appointments', { accountScoped: true });
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

  cancel(id) {
    return axios.post(`${this.url}/${id}/cancel`);
  }
}

export default new SchedulingAppointmentsAPI();
