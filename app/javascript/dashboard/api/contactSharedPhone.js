/* global axios */
import ApiClient from './ApiClient';

// Family number of a contact card: notification route, promotion hint and preview (masked numbers only).
class ContactSharedPhoneAPI extends ApiClient {
  constructor() {
    super('contacts', { accountScoped: true });
  }

  get(contactId) {
    return axios.get(`${this.url}/${contactId}/shared_phone`);
  }

  promote(contactId, fingerprint) {
    return axios.post(`${this.url}/${contactId}/shared_phone/promote`, {
      fingerprint,
    });
  }

  dismissHint(contactId) {
    return axios.post(`${this.url}/${contactId}/shared_phone/dismiss_hint`);
  }
}

export default new ContactSharedPhoneAPI();
