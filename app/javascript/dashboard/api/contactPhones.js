/* global axios */
import ApiClient from './ApiClient';

class ContactPhonesAPI extends ApiClient {
  constructor() {
    super('contacts', { accountScoped: true });
  }

  create(contactId, payload) {
    return axios.post(`${this.url}/${contactId}/phones`, payload);
  }

  setPrimary(contactId, phoneId) {
    return axios.patch(
      `${this.url}/${contactId}/phones/${phoneId}/set_primary`
    );
  }

  destroy(contactId, phoneId) {
    return axios.delete(`${this.url}/${contactId}/phones/${phoneId}`);
  }
}

export default new ContactPhonesAPI();
