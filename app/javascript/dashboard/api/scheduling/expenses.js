/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingExpensesAPI extends ApiClient {
  constructor() {
    super('scheduling/expenses', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  pay(id) {
    return axios.post(`${this.url}/${id}/pay`);
  }

  payAll(data = {}) {
    return axios.post(`${this.url}/pay_all`, data);
  }
}

export default new SchedulingExpensesAPI();
