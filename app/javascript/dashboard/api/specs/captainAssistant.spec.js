import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import CaptainAssistant from '../captain/assistant';

describe('CaptainAssistant playground API', () => {
  const originalAxios = window.axios;
  const axiosMock = {
    post: vi.fn(),
  };

  beforeEach(() => {
    window.axios = axiosMock;
    axiosMock.post.mockReset();
  });

  afterEach(() => {
    window.axios = originalAxios;
  });

  it('sends test-only model controls as playground request fields', () => {
    CaptainAssistant.playground({
      assistantId: 42,
      messageContent: 'Check this response',
      messageHistory: [{ role: 'user', content: 'Earlier question' }],
      testOptions: {
        model: 'openai/gpt-5.4',
        temperature: 0.4,
        thinkingEffort: 'high',
      },
    });

    expect(axiosMock.post).toHaveBeenCalledWith(
      '/api/v1/captain/assistants/42/playground',
      {
        message_content: 'Check this response',
        message_history: [{ role: 'user', content: 'Earlier question' }],
        test_model: 'openai/gpt-5.4',
        test_temperature: 0.4,
        test_thinking_effort: 'high',
      }
    );
  });

  it('sends only the selected Trial session and does not include Live delivery fields', () => {
    CaptainAssistant.playground({
      assistantId: 42, messageContent: 'Trial', messageHistory: [], mode: 'trial', sessionId: 'trial-session',
    });
    expect(axiosMock.post.mock.lastCall[1]).toEqual({
      message_content: 'Trial', message_history: [], playground_mode: 'trial', playground_session_id: 'trial-session',
    });
  });

  it('uses the actual Live conversation and starts with delivery disabled', () => {
    CaptainAssistant.playground({
      assistantId: 42, messageContent: 'Live', messageHistory: [], mode: 'live', sessionId: 'live-session', conversationId: 27,
      liveOptions: { inboxId: 7 },
    });
    expect(axiosMock.post.mock.lastCall[1]).toEqual({
      message_content: 'Live', message_history: [], playground_mode: 'live', playground_session_id: 'live-session',
      conversation_id: 27, live_inbox_id: 7, external_delivery_enabled: false,
    });
  });

  it('sends a controlled phone only when explicitly enabling Live delivery and preserves zero temperature', () => {
    CaptainAssistant.playground({
      assistantId: 42, mode: 'live', liveOptions: { deliveryEnabled: true, testNumber: '+77015551234' }, testOptions: { temperature: 0 },
    });
    expect(axiosMock.post.mock.lastCall[1]).toMatchObject({
      external_delivery_enabled: true, controlled_test_number: '+77015551234', test_temperature: 0,
    });
  });

  it('edits and resets the server scenario through the same Playground endpoint', () => {
    CaptainAssistant.playgroundSession({
      assistantId: 42, sessionId: 'trial-session', reset: true, scenario: { contact: { name: 'Mother' } },
    });
    expect(axiosMock.post).toHaveBeenCalledWith('/api/v1/captain/assistants/42/playground', {
      playground_action: 'reset', playground_mode: 'trial', playground_session_id: 'trial-session', scenario: { contact: { name: 'Mother' } },
    });
  });
});
