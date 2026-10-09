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
});
