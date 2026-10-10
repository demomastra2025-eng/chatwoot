/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class SchedulingContactsAPI extends ApiClient {
  constructor() {
    super('scheduling/contacts', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  create(data) {
    return axios.post(this.url, data);
  }

  update(id, data) {
    return axios.patch(`${this.url}/${id}`, data);
  }

  patients(contactId) {
    return axios.get(`${this.url}/${contactId}/patients`);
  }

  createPatient(contactId, data) {
    return axios.post(`${this.url}/${contactId}/patients`, data);
  }
}

export default new SchedulingContactsAPI();
