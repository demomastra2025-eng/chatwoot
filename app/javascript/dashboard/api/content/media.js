/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class ContentMediaAPI extends ApiClient {
  constructor() {
    super('content/media', { accountScoped: true });
  }

  upload(file) {
    const formData = new FormData();
    formData.append('file', file);
    return axios.post(this.url, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  uploadFromUrl(url) {
    return axios.post(`${this.url}/upload_from_url`, { url });
  }
}

export default new ContentMediaAPI();
