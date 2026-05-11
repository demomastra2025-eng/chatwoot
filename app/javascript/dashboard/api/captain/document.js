/* global axios */
import ApiClient from '../ApiClient';

class CaptainDocument extends ApiClient {
  constructor() {
    super('captain/documents', { accountScoped: true });
  }

  get({ page = 1, searchKey, assistantId } = {}) {
    return axios.get(this.url, {
      params: {
        page,
        searchKey,
        assistant_id: assistantId,
      },
    });
  }

  preview(data) {
    return axios.post(`${this.url}/preview`, data);
  }

  sourceText(id) {
    return axios.get(`${this.url}/${id}/source_text`);
  }

  resync(id) {
    return axios.post(`${this.url}/${id}/resync`);
  }

  refreshChangedOnly(id) {
    return axios.post(`${this.url}/${id}/refresh_changed_only`);
  }

  retryFailed(id) {
    return axios.post(`${this.url}/${id}/retry_failed`);
  }
}

export default new CaptainDocument();
