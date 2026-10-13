/* global axios */
import ApiClient from './ApiClient';

class AutomationsAPI extends ApiClient {
  constructor() {
    super('automation_rules', { accountScoped: true });
  }

  clone(automationId) {
    return axios.post(`${this.url}/${automationId}/clone`);
  }

  // Contacts for the "Contact" condition: a page found by name or phone
  // ({ q, page }) or the contacts behind saved ids ({ ids }).
  contactOptions(params = {}) {
    return axios.get(`${this.url}/contact_options`, { params });
  }
}

export default new AutomationsAPI();
