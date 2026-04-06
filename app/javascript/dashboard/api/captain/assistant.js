/* global axios */
import ApiClient from '../ApiClient';

class CaptainAssistant extends ApiClient {
  constructor() {
    super('captain/assistants', { accountScoped: true });
  }

  get({ page = 1, searchKey } = {}) {
    return axios.get(this.url, {
      params: {
        page,
        searchKey,
      },
    });
  }

  playground({ assistantId, messageContent, messageHistory }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      message_content: messageContent,
      message_history: messageHistory,
    });
  }

  promptPreview(assistantId) {
    return axios.get(`${this.url}/${assistantId}/prompt_preview`);
  }

  updateAvatar(assistantId, avatar) {
    const formData = new FormData();
    formData.append('avatar', avatar);

    return axios.patch(`${this.url}/${assistantId}/avatar`, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  deleteAvatar(assistantId) {
    return axios.delete(`${this.url}/${assistantId}/avatar`);
  }
}

export default new CaptainAssistant();
