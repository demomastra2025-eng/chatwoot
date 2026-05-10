/* global axios */
import ApiClient from './ApiClient';

class UserNotificationSettings extends ApiClient {
  constructor() {
    super('notification_settings', { accountScoped: true });
  }

  update(params) {
    return axios.patch(`${this.url}`, params);
  }

  disconnectTelegram() {
    return axios.delete(`${this.url}/disconnect_telegram`);
  }
}

export default new UserNotificationSettings();
