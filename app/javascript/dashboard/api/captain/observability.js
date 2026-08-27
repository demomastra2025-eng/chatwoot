/* global axios */
import ApiClient from '../ApiClient';

class CaptainObservability extends ApiClient {
  constructor() {
    super('captain/observability', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  export(params = {}, format = 'json') {
    return axios.get(`${this.url}/export`, {
      params: { ...params, export_format: format },
      responseType: 'blob',
    });
  }

  metrics(params = {}) {
    return axios.get(`${this.url}/metrics`, {
      params,
      responseType: 'text',
    });
  }

  releaseCheck(params = {}) {
    return axios.get(`${this.url}/release_check`, { params });
  }

  deleteEvent(eventId) {
    return axios.delete(`${this.url}/event`, { params: { event_id: eventId } });
  }

  clear() {
    return axios.delete(`${this.url}/clear`);
  }

  listAnnotations(eventId) {
    return axios.get(`${this.url}/annotations`, {
      params: { event_id: eventId },
    });
  }

  createAnnotation(payload) {
    return axios.post(`${this.url}/annotations`, payload);
  }

  deleteAnnotation(id, eventId) {
    return axios.delete(`${this.url}/annotations/${id}`, {
      params: { event_id: eventId },
    });
  }
}

export default new CaptainObservability();
