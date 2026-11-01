/* global axios */
import ApiClient from '../ApiClient';

class TelegramSoftphoneAPI extends ApiClient {
  constructor() {
    super('telephony/telegram_softphone', { accountScoped: true });
  }

  getStatus() {
    if (typeof axios === 'undefined') {
      return Promise.resolve({
        configured: false,
        connected: false,
        on_line: false,
      });
    }
    return axios
      .get(this.url)
      .then(response => response.data?.payload || response.data);
  }

  issueLinkToken() {
    return axios
      .post(`${this.url}/link_token`)
      .then(response => response.data?.payload || response.data);
  }

  setOnLine(onLine) {
    return axios
      .patch(this.url, { on_line: Boolean(onLine) })
      .then(response => response.data?.payload || response.data);
  }

  disconnect() {
    return axios
      .delete(this.url)
      .then(response => response.data?.payload || response.data);
  }
}

export default new TelegramSoftphoneAPI();
