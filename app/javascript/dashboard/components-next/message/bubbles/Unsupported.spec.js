import { describe, expect, it, beforeEach, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import Unsupported from './Unsupported.vue';

const useInboxMock = vi.fn();

vi.mock('../provider.js', () => ({
  useMessageContext: () => ({ inboxId: { value: 1 } }),
}));

vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: (...args) => useInboxMock(...args),
}));

const inboxFlags = overrides => ({
  isAFacebookInbox: ref(false),
  isAnInstagramChannel: ref(false),
  isATiktokChannel: ref(false),
  isAWhatsAppChannel: ref(false),
  isAWhatsAppWebChannel: ref(false),
  ...overrides,
});

const createWrapper = () =>
  shallowMount(Unsupported, {
    global: {
      stubs: {
        BaseBubble: { template: '<div><slot /></div>' },
      },
      mocks: {
        $t: key =>
          ({
            'CONVERSATION.UNSUPPORTED_MESSAGE': 'Unsupported fallback',
            'CONVERSATION.UNSUPPORTED_MESSAGE_WHATSAPP':
              'This WhatsApp message is unavailable.',
          })[key] || key,
      },
    },
  });

describe('Unsupported', () => {
  beforeEach(() => {
    useInboxMock.mockReset();
    useInboxMock.mockReturnValue(inboxFlags());
  });

  it('renders a non-blank generic unsupported message', () => {
    const wrapper = createWrapper();

    expect(wrapper.text()).toContain('Unsupported fallback');
  });

  it('renders a WhatsApp-specific unavailable message for WhatsApp channels', () => {
    useInboxMock.mockReturnValue(inboxFlags({ isAWhatsAppChannel: ref(true) }));

    const wrapper = createWrapper();

    expect(wrapper.text()).toContain('This WhatsApp message is unavailable.');
  });

  it('renders a WhatsApp-specific unavailable message for WhatsApp Web channels', () => {
    useInboxMock.mockReturnValue(
      inboxFlags({ isAWhatsAppWebChannel: ref(true) })
    );

    const wrapper = createWrapper();

    expect(wrapper.text()).toContain('This WhatsApp message is unavailable.');
  });
});
