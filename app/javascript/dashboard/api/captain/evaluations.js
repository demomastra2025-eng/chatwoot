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

  runLive(payload = {}) {
    return axios.post(`${this.url}/run_live`, payload);
  }

  getLiveRun(runId) {
    return axios.get(`${this.url}/live_run`, { params: { run_id: runId } });
  }

  importConversation(payload = {}) {
    return axios.post(`${this.url}/import_conversation`, payload);
  }
}

export default new CaptainEvaluations();
