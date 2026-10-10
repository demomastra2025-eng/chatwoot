/* global axios */
import ApiClient from '../ApiClient';

const normalizeAssistantPayload = (data = {}) => {
  if (Object.prototype.hasOwnProperty.call(data, 'assistant')) {
    return data;
  }

  return { assistant: data };
};

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

  playground({ assistantId, messageContent, testOptions = {}, sessionId }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      playground_mode: 'workspace',
      message_content: messageContent,
      playground_session_id: sessionId,
      ...(testOptions.model ? { test_model: testOptions.model } : {}),
      ...(testOptions.temperature !== null &&
      testOptions.temperature !== undefined
        ? { test_temperature: testOptions.temperature }
        : {}),
      ...(testOptions.thinkingEffort
        ? { test_thinking_effort: testOptions.thinkingEffort }
        : {}),
    });
  }

  playgroundSession({ assistantId, sessionId, reset = false, scenario }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      playground_mode: 'workspace',
      playground_action: reset ? 'reset' : 'session',
      ...(sessionId ? { playground_session_id: sessionId } : {}),
      ...(scenario ? { scenario } : {}),
    });
  }

  playgroundPermissions({ assistantId, sessionId, read, write }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      playground_mode: 'workspace',
      playground_action: 'permissions',
      playground_session_id: sessionId,
      real_data_read: read === true,
      real_data_write: read === true && write === true,
    });
  }

  confirmPlaygroundAction({ assistantId, sessionId, approval }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      playground_mode: 'workspace',
      playground_action: 'confirm',
      playground_session_id: sessionId,
      approval_id: approval.id,
      approval_digest: approval.digest,
    });
  }

  promptPreview(assistantId) {
    return axios.get(`${this.url}/${assistantId}/prompt_preview`);
  }

  voicePreview(assistantId) {
    return axios.post(`${this.url}/${assistantId}/voice_preview`);
  }

  create(data) {
    return axios.post(this.url, normalizeAssistantPayload(data));
  }

  update(id, data) {
    return axios.patch(`${this.url}/${id}`, normalizeAssistantPayload(data));
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
