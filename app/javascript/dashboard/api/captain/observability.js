/* global axios */
import ApiClient from '../ApiClient';

class CaptainObservability extends ApiClient {
  constructor() {
    super('captain/observability', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new CaptainObservability();
