/* global axios */
import ApiClient from '../ApiClient';

// The Playground of the AI. It has no start agent: the AI picks the agent that
// answers each message among the enabled agents of the workspace. `inboxId`
// picks a channel (a voice channel gives the agent of that number alone);
// without it the enabled agents of the workspace work as in a text channel.
class CaptainPlayground extends ApiClient {
  constructor() {
    super('captain/playground', { accountScoped: true });
  }

  message({ messageContent, testOptions = {}, sessionId, inboxId }) {
    return axios.post(this.url, {
      playground_mode: 'workspace',
      message_content: messageContent,
      playground_session_id: sessionId,
      ...(inboxId ? { inbox_id: inboxId } : {}),
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

  // A reset starts a new session, so the channel is sent again with it.
  session({ sessionId, reset = false, scenario, inboxId } = {}) {
    return axios.post(this.url, {
      playground_mode: 'workspace',
      playground_action: reset ? 'reset' : 'session',
      ...(sessionId ? { playground_session_id: sessionId } : {}),
      ...(inboxId ? { inbox_id: inboxId } : {}),
      ...(scenario ? { scenario } : {}),
    });
  }

  permissions({ sessionId, read, write }) {
    return axios.post(this.url, {
      playground_mode: 'workspace',
      playground_action: 'permissions',
      playground_session_id: sessionId,
      real_data_read: read === true,
      real_data_write: read === true && write === true,
    });
  }

  confirmAction({ sessionId, approval, inboxId }) {
    return axios.post(this.url, {
      playground_mode: 'workspace',
      playground_action: 'confirm',
      playground_session_id: sessionId,
      ...(inboxId ? { inbox_id: inboxId } : {}),
      approval_id: approval.id,
      approval_digest: approval.digest,
    });
  }
}

export default new CaptainPlayground();
