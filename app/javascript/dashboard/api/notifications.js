/* global axios */
import ApiClient from './ApiClient';

class NotificationsAPI extends ApiClient {
  constructor() {
    super('notifications', { accountScoped: true });
  }

  // `cursor` ({ id, lastActivityAt }) is the last notification of the
  // previous page: the next page starts right after it, so notifications
  // archived or added between pages shift nothing.
  get({ page, status, type, sortOrder, cursor }) {
    const includesFilter = [status, type].filter(value => !!value);
    const params = {
      page,
      sort_order: sortOrder,
      includes: includesFilter,
    };
    if (cursor?.id) {
      params.cursor_id = cursor.id;
      params.cursor_last_activity_at = cursor.lastActivityAt;
    }

    return axios.get(this.url, { params });
  }

  getNotifications(contactId) {
    return axios.get(`${this.url}/${contactId}/notifications`);
  }

  getUnreadCount() {
    return axios.get(`${this.url}/unread_count`);
  }

  read(primaryActorType, primaryActorId) {
    return axios.post(`${this.url}/read_all`, {
      primary_actor_type: primaryActorType,
      primary_actor_id: primaryActorId,
    });
  }

  unRead(id) {
    return axios.post(`${this.url}/${id}/unread`);
  }

  readAll() {
    return axios.post(`${this.url}/read_all`);
  }

  // Marks only this notification as read, unlike `read`, which marks every
  // notification of the primary actor.
  archive(id) {
    return axios.patch(`${this.url}/${id}`);
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  deleteAll({ type = 'all' }) {
    return axios.post(`${this.url}/destroy_all`, {
      type,
    });
  }

  snooze({ id, snoozedUntil = null }) {
    return axios.post(`${this.url}/${id}/snooze`, {
      snoozed_until: snoozedUntil,
    });
  }
}

export default new NotificationsAPI();
