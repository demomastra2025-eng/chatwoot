/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmFieldDefinitionsAPI extends ApiClient {
  constructor() {
    super('crm/field_definitions', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }
}

export default new CrmFieldDefinitionsAPI();
