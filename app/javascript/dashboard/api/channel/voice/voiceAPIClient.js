/* global axios */
import ApiClient from '../../ApiClient';
import ContactsAPI from '../../contacts';

class VoiceAPI extends ApiClient {
  constructor() {
    super('voice', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  initiateCall(contactId, inboxId) {
    return ContactsAPI.initiateCall(contactId, inboxId).then(r => r.data);
  }

  leaveConference(inboxId, conversationId) {
    return axios
      .delete(`${this.baseUrl()}/inboxes/${inboxId}/conference`, {
        params: { conversation_id: conversationId },
      })
      .then(r => r.data);
  }

  joinConference({ conversationId, inboxId, callSid }) {
    return axios
      .post(`${this.baseUrl()}/inboxes/${inboxId}/conference`, {
        conversation_id: conversationId,
        call_sid: callSid,
      })
      .then(r => r.data);
  }

  getWebphoneToken(inboxId = null) {
    if (inboxId) {
      return axios
        .get(`${this.baseUrl()}/inboxes/${inboxId}/conference/token`)
        .then(r => r.data);
    }

    return axios
      .post(`${this.baseUrl()}/telephony/webphone/token`)
      .then(r => r.data.payload || r.data);
  }

  getToken(inboxId) {
    return this.getWebphoneToken(inboxId);
  }

  getReadiness() {
    return axios
      .get(`${this.baseUrl()}/telephony/resources/readiness`)
      .then(r => r.data);
  }

  updateNumberRoute(numberRef, payload) {
    return axios
      .post(
        `${this.baseUrl()}/telephony/numbers/${encodeURIComponent(numberRef)}/route`,
        payload
      )
      .then(r => r.data);
  }
}

export default new VoiceAPI();
