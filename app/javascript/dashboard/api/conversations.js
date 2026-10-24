/* global axios */
import ApiClient from './ApiClient';

class ConversationApi extends ApiClient {
  constructor() {
    super('conversations', { accountScoped: true });
  }

  getLabels(conversationID) {
    return axios.get(`${this.url}/${conversationID}/labels`);
  }

  // Sends the whole list. Prefer changeLabels: a list that is out of date erases labels it never saw.
  updateLabels(conversationID, labels) {
    return axios.post(`${this.url}/${conversationID}/labels`, { labels });
  }

  // Labels belong to the person: add / remove are applied to the contact and to all its conversations.
  changeLabels(conversationID, { add = [], remove = [] } = {}) {
    return axios.post(`${this.url}/${conversationID}/labels`, { add, remove });
  }
}

export default new ConversationApi();
