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

  playground({
    assistantId,
    messageContent,
    messageHistory,
    testOptions = {},
    mode,
    sessionId,
    conversationId,
    liveOptions = {},
  }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      message_content: messageContent,
      message_history: messageHistory,
      ...(mode ? { playground_mode: mode } : {}),
      ...(sessionId ? { playground_session_id: sessionId } : {}),
      ...(conversationId ? { conversation_id: conversationId } : {}),
      ...(liveOptions.inboxId ? { live_inbox_id: liveOptions.inboxId } : {}),
      ...(mode === 'live'
        ? {
            external_delivery_enabled: liveOptions.deliveryEnabled === true,
            ...(liveOptions.deliveryEnabled && liveOptions.testNumber
              ? { controlled_test_number: liveOptions.testNumber }
              : {}),
          }
        : {}),
      ...(testOptions.model ? { test_model: testOptions.model } : {}),
      ...(testOptions.temperature !== undefined
        ? { test_temperature: testOptions.temperature }
        : {}),
      ...(testOptions.thinkingEffort
        ? { test_thinking_effort: testOptions.thinkingEffort }
        : {}),
    });
  }

  playgroundSession({ assistantId, mode = 'trial', sessionId, reset = false, scenario, liveOptions = {} }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      playground_action: reset ? 'reset' : 'session',
      playground_mode: mode,
      ...(sessionId ? { playground_session_id: sessionId } : {}),
      ...(scenario ? { scenario } : {}),
      ...(liveOptions.inboxId ? { live_inbox_id: liveOptions.inboxId } : {}),
      ...(mode === 'live'
        ? {
            external_delivery_enabled: liveOptions.deliveryEnabled === true,
            ...(liveOptions.deliveryEnabled && liveOptions.testNumber
              ? { controlled_test_number: liveOptions.testNumber }
              : {}),
          }
        : {}),
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
