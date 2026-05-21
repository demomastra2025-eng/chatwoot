/* global axios */
import ApiClient from '../ApiClient';

class CaptainEvaluations extends ApiClient {
  constructor() {
    super('captain/evaluations', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  run(payload = {}) {
    return axios.post(`${this.url}/run`, payload);
  }
}

export default new CaptainEvaluations();
