/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class CrmDealsAPI extends ApiClient {
  constructor() {
    super('crm/deals', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  transitionStage(id, data) {
    return axios.post(`${this.url}/${id}/transition_stage`, data);
  }

  closeWon(id, data) {
    return axios.post(`${this.url}/${id}/close_won`, data);
  }

  closeLost(id, data) {
    return axios.post(`${this.url}/${id}/close_lost`, data);
  }

  reopen(id, data) {
    return axios.post(`${this.url}/${id}/reopen`, data);
  }

  reorder(id, data) {
    return axios.post(`${this.url}/${id}/reorder`, data);
  }

  undoTransition(id, data) {
    return axios.post(`${this.url}/${id}/undo_transition`, data);
  }

  setWaiting(id, data) {
    return axios.post(`${this.url}/${id}/set_waiting`, data);
  }

  clearWaiting(id, data) {
    return axios.post(`${this.url}/${id}/clear_waiting`, data);
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

export default new CrmDealsAPI();
