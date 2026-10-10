import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import CaptainAssistant from '../captain/assistant';

describe('CaptainAssistant playground API', () => {
  const originalAxios = window.axios;
  const axiosMock = { post: vi.fn() };
  beforeEach(() => {
    window.axios = axiosMock;
    axiosMock.post.mockReset();
  });
  afterEach(() => {
    window.axios = originalAxios;
  });

  it('sends only session controls and explicit per-session model overrides', () => {
    CaptainAssistant.playground({
      assistantId: 42,
      sessionId: 'workspace-session',
      messageContent: 'Check this response',
      messageHistory: [{ role: 'user', content: 'Forged history' }],
      testOptions: {
        model: 'openai/gpt-5.4',
        temperature: 0.4,
        thinkingEffort: 'high',
      },
    });
    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/captain/assistants/42/playground',
      {
        playground_mode: 'workspace',
        playground_session_id: 'workspace-session',
        message_content: 'Check this response',
        test_model: 'openai/gpt-5.4',
        test_temperature: 0.4,
        test_thinking_effort: 'high',
      }
    );
  });

  it('ignores legacy Live caller/delivery arguments and preserves zero temperature', () => {
    CaptainAssistant.playground({
      assistantId: 42,
      sessionId: 'workspace-session',
      messageContent: 'Synthetic',
      mode: 'live',
      conversationId: 27,
      liveOptions: {
        inboxId: 7,
        deliveryEnabled: true,
        testNumber: '+77015551234',
      },
      testOptions: { temperature: 0 },
    });
    expect(axiosMock.post.mock.lastCall[1]).toEqual({
      playground_mode: 'workspace',
      playground_session_id: 'workspace-session',
      message_content: 'Synthetic',
      test_temperature: 0,
    });
  });

  it('omits model parameters when provider defaults are selected', () => {
    CaptainAssistant.playground({
      assistantId: 42,
      messageContent: 'Default',
      testOptions: { temperature: null, thinkingEffort: '' },
    });
    expect(axiosMock.post.mock.lastCall[1]).not.toHaveProperty(
      'test_temperature'
    );
    expect(axiosMock.post.mock.lastCall[1]).not.toHaveProperty(
      'test_thinking_effort'
    );
    expect(axiosMock.post.mock.lastCall[1]).not.toHaveProperty('test_model');
  });

  it('edits and resets the synthetic session through the same endpoint', () => {
    CaptainAssistant.playgroundSession({
      assistantId: 42,
      sessionId: 'workspace-session',
      reset: true,
      scenario: { contact: { name: 'Mother' } },
    });
    expect(axiosMock.post.mock.lastCall[1]).toEqual({
      playground_action: 'reset',
      playground_mode: 'workspace',
      playground_session_id: 'workspace-session',
      scenario: { contact: { name: 'Mother' } },
    });
  });

  it('forces write off with read off and confirms only the server-owned preview handle', () => {
    CaptainAssistant.playgroundPermissions({
      assistantId: 42,
      sessionId: 'workspace-session',
      read: false,
      write: true,
    });
    expect(axiosMock.post.mock.lastCall[1]).toMatchObject({
      real_data_read: false,
      real_data_write: false,
    });
    CaptainAssistant.confirmPlaygroundAction({
      assistantId: 42,
      sessionId: 'workspace-session',
      approval: {
        id: 'approval-id',
        digest: 'exact-digest',
        arguments: { forged: true },
      },
    });
    expect(axiosMock.post.mock.lastCall[1]).toEqual({
      playground_action: 'confirm',
      playground_mode: 'workspace',
      playground_session_id: 'workspace-session',
      approval_id: 'approval-id',
      approval_digest: 'exact-digest',
    });
  });
});
