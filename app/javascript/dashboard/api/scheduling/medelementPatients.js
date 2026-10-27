/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingMedelementPatientsAPI extends ApiClient {
  constructor() {
    super('scheduling/medelement_patients', { accountScoped: true });
  }

  searchMedelementPatients(query, signal) {
    return axios.post(`${this.url}/search`, { query }, { signal });
  }

  importMedelementPatient(token) {
    return axios.post(this.url, { token });
  }
}

export default new SchedulingMedelementPatientsAPI();
