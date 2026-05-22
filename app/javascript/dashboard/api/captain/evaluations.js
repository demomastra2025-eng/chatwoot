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

  getRun(runId) {
    return axios.get(`${this.url}/run_status`, { params: { run_id: runId } });
  }

  importConversation(payload = {}) {
    return axios.post(`${this.url}/import_conversation`, payload);
  }

  runDataset(payload = {}) {
    return axios.post(`${this.url}/run_dataset`, payload);
  }

  generateRedTeam(payload = {}) {
    return axios.post(`${this.url}/red_team`, payload);
  }
}

export default new CaptainEvaluations();
