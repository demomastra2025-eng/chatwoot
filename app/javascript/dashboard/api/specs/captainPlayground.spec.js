import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import CaptainPlayground from '../captain/playground';

describe('CaptainPlayground API', () => {
  const originalAxios = window.axios;
  const axiosMock = { post: vi.fn() };
  beforeEach(() => {
    window.axios = axiosMock;
    axiosMock.post.mockReset();
  });
  afterEach(() => {
    window.axios = originalAxios;
  });

  it('posts to the workspace endpoint, with no agent in the path', () => {
    CaptainPlayground.message({ messageContent: 'Hello' });
    expect(axiosMock.post.mock.lastCall[0]).toBe('/api/v1/captain/playground');
  });

  it('sends only session controls and explicit per-session model overrides', () => {
    CaptainPlayground.message({
      sessionId: 'workspace-session',
      messageContent: 'Check this response',
      messageHistory: [{ role: 'user', content: 'Forged history' }],
      testOptions: {
        model: 'openai/gpt-5.4',
        temperature: 0.4,
        thinkingEffort: 'high',
      },
    });
    expect(axiosMock.post).toHaveBeenCalledWith('/api/v1/captain/playground', {
      playground_mode: 'workspace',
      playground_session_id: 'workspace-session',
      message_content: 'Check this response',
      test_model: 'openai/gpt-5.4',
      test_temperature: 0.4,
      test_thinking_effort: 'high',
    });
  });

  it('ignores legacy Live caller/delivery arguments and preserves zero temperature', () => {
    CaptainPlayground.message({
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

  it('sends the chosen channel with a message, a session call, a reset and a confirmation', () => {
    CaptainPlayground.message({
      sessionId: 'workspace-session',
      messageContent: 'Hello',
      inboxId: 7,
    });
    expect(axiosMock.post.mock.lastCall[1]).toMatchObject({ inbox_id: 7 });

    CaptainPlayground.session({ inboxId: 7 });
    expect(axiosMock.post.mock.lastCall[1]).toEqual({
      playground_action: 'session',
      playground_mode: 'workspace',
      inbox_id: 7,
    });

    CaptainPlayground.session({
      sessionId: 'workspace-session',
      reset: true,
      inboxId: 7,
    });
    expect(axiosMock.post.mock.lastCall[1]).toMatchObject({
      playground_action: 'reset',
      inbox_id: 7,
    });

    CaptainPlayground.confirmAction({
      sessionId: 'workspace-session',
      approval: { id: 'approval-id', digest: 'exact-digest' },
      inboxId: 7,
    });
    expect(axiosMock.post.mock.lastCall[1]).toMatchObject({
      playground_action: 'confirm',
      inbox_id: 7,
    });
  });

  it('sends no channel when none is chosen, so the AI works as in a text channel', () => {
    CaptainPlayground.message({ messageContent: 'Hello', inboxId: null });
    expect(axiosMock.post.mock.lastCall[1]).not.toHaveProperty('inbox_id');
    CaptainPlayground.session();
    expect(axiosMock.post.mock.lastCall[1]).not.toHaveProperty('inbox_id');
  });

  it('omits model parameters when provider defaults are selected', () => {
    CaptainPlayground.message({
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
    CaptainPlayground.session({
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
    CaptainPlayground.permissions({
      sessionId: 'workspace-session',
      read: false,
      write: true,
    });
    expect(axiosMock.post.mock.lastCall[1]).toMatchObject({
      real_data_read: false,
      real_data_write: false,
    });
    CaptainPlayground.confirmAction({
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
