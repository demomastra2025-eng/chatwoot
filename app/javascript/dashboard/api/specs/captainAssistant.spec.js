import ApiClient from '../ApiClient';
import captainAssistantAPI from '../captain/assistant';

describe('#CaptainAssistantAPI', () => {
  it('creates correct instance', () => {
    expect(captainAssistantAPI).toBeInstanceOf(ApiClient);
    expect(captainAssistantAPI).toHaveProperty('create');
    expect(captainAssistantAPI).toHaveProperty('update');
    expect(captainAssistantAPI).toHaveProperty('promptPreview');
    expect(captainAssistantAPI).toHaveProperty('voicePreview');
  });

  describe('assistant payload contract', () => {
    const originalAxios = window.axios;
    const originalPathname = window.location.pathname;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      patch: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
      window.history.pushState({}, '', '/app/accounts/1/captain/12/prompts');
      axiosMock.post.mockClear();
      axiosMock.patch.mockClear();
    });

    afterEach(() => {
      window.axios = originalAxios;
      window.history.pushState({}, '', originalPathname);
    });

    it('wraps plain create payloads under assistant', () => {
      captainAssistantAPI.create({
        name: 'Billing agent',
        config: { feature_faq: true },
      });

      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/accounts/1/captain/assistants',
        {
          assistant: {
            name: 'Billing agent',
            config: { feature_faq: true },
          },
        }
      );
    });

    it('wraps plain update payloads under assistant', () => {
      captainAssistantAPI.update(42, {
        config: {
          rules: [
            {
              id: 'response_rule',
              type: 'response_guideline',
              group: 'Conversation flow',
              content: 'Ask one clarifying question before assuming.',
              enabled: true,
            },
          ],
        },
      });

      expect(axiosMock.patch).toHaveBeenCalledWith(
        '/api/v1/accounts/1/captain/assistants/42',
        {
          assistant: {
            config: {
              rules: [
                {
                  id: 'response_rule',
                  type: 'response_guideline',
                  group: 'Conversation flow',
                  content: 'Ask one clarifying question before assuming.',
                  enabled: true,
                },
              ],
            },
          },
        }
      );
    });

    it('preserves already wrapped assistant payloads', () => {
      captainAssistantAPI.update(42, {
        assistant: {
          guardrails: ['Never ask for passwords'],
        },
      });

      expect(axiosMock.patch).toHaveBeenCalledWith(
        '/api/v1/accounts/1/captain/assistants/42',
        {
          assistant: {
            guardrails: ['Never ask for passwords'],
          },
        }
      );
    });
  });
});
