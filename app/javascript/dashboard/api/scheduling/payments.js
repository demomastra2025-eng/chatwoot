/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingPaymentsAPI extends ApiClient {
  constructor() {
    super('scheduling', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(`${this.url}/payments`, { params });
  }

  addPayment(appointmentId, data) {
    return axios.post(
      `${this.url}/appointments/${appointmentId}/payments`,
      data
    );
  }

  cancelPayments(appointmentId) {
    return axios.delete(`${this.url}/appointments/${appointmentId}/payments`);
  }
}

export default new SchedulingPaymentsAPI();
