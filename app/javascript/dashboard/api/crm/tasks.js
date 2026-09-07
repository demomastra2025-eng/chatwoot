/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmTasksAPI extends ApiClient {
  constructor() {
    super('crm/tasks', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  changeStatus(id, data) {
    return axios.post(`${this.url}/${id}/change_status`, data);
  }

  complete(id, data) {
    return axios.post(`${this.url}/${id}/complete`, data);
  }

  cancel(id, data) {
    return axios.post(`${this.url}/${id}/cancel`, data);
  }

  reopen(id, data) {
    return axios.post(`${this.url}/${id}/reopen`, data);
  }

  reschedule(id, data) {
    return axios.post(`${this.url}/${id}/reschedule`, data);
  }

  assign(id, data) {
    return axios.post(`${this.url}/${id}/assign`, data);
  }

  saveForm(id, data) {
    return axios.post(`${this.url}/${id}/save_form`, data);
  }

  archive(id, data = {}) {
    return axios.post(`${this.url}/${id}/archive`, data);
  }

  unarchive(id, data = {}) {
    return axios.post(`${this.url}/${id}/unarchive`, data);
  }

  timeline(id, params = {}) {
    return axios.get(`${this.url}/${id}/timeline`, { params });
  }

  getComments(id, params = {}) {
    return axios.get(`${this.url}/${id}/comments`, { params });
  }

  createComment(id, data) {
    return axios.post(`${this.url}/${id}/comments`, data);
  }

  updateComment(id, commentId, data) {
    return axios.patch(`${this.url}/${id}/comments/${commentId}`, data);
  }

  deleteComment(id, commentId) {
    return axios.delete(`${this.url}/${id}/comments/${commentId}`);
  }
}

export default new CrmTasksAPI();
