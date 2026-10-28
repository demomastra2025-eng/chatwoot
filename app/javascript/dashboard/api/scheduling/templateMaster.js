/* global axios */
import ApiClient from '../ApiClient';

class SchedulingTemplateMasterAPI extends ApiClient {
  constructor() {
    super('scheduling/template_master', { accountScoped: true });
  }

  generate(payload = {}) {
    return axios.post(`${this.baseUrl()}/generate`, payload);
  }

  validate(payload = {}) {
    return axios.post(`${this.baseUrl()}/validate`, payload);
  }
}

export default new SchedulingTemplateMasterAPI();
