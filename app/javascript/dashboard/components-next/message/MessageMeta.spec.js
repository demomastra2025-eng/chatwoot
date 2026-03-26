import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import MessageMeta from './MessageMeta.vue';
import { MESSAGE_STATUS, MESSAGE_TYPES } from './constants';

vi.mock('shared/helpers/timeHelper', () => ({
  messageTimestamp: vi.fn(() => 'Mar 26, 6:51 AM'),
}));

const useInboxMock = vi.fn();
vi.mock('dashboard/composables/useInbox', () => ({
  useInbox: () => useInboxMock(),
}));

const useMessageContextMock = vi.fn();
vi.mock('./provider.js', () => ({
  useMessageContext: () => useMessageContextMock(),
}));

const baseInboxState = () => ({
  isAFacebookInbox: ref(false),
  isALineChannel: ref(false),
  isAPIInbox: ref(false),
  isASmsInbox: ref(false),
  isATelegramChannel: ref(false),
  isATwilioChannel: ref(false),
  isAWebWidgetInbox: ref(false),
  isAWhatsAppChannel: ref(false),
  isAWhatsAppWebChannel: ref(true),
  isAnEmailChannel: ref(false),
  isAnInstagramChannel: ref(false),
  isATiktokChannel: ref(false),
});

const baseMessageContext = status => ({
  status: ref(status),
  isPrivate: ref(false),
  createdAt: ref(1774504297),
  sourceId: ref('A59662051F54F088C7D7C25E1C02FBF1'),
  messageType: ref(MESSAGE_TYPES.OUTGOING),
  contentAttributes: ref({ externalEcho: true }),
});

const mountComponent = () =>
  shallowMount(MessageMeta, {
    global: {
      stubs: {
        Icon: true,
        MessageStatus: {
          name: 'MessageStatus',
          props: ['status'],
          template: '<div />',
        },
      },
    },
  });

describe('MessageMeta', () => {
  beforeEach(() => {
    useInboxMock.mockReturnValue(baseInboxState());
  });

  it.each([
    [MESSAGE_STATUS.SENT, MESSAGE_STATUS.SENT],
    [MESSAGE_STATUS.DELIVERED, MESSAGE_STATUS.DELIVERED],
    [MESSAGE_STATUS.READ, MESSAGE_STATUS.READ],
  ])(
    'shows %s status for WhatsApp Web outgoing messages',
    (messageStatus, expectedStatus) => {
      useMessageContextMock.mockReturnValue(baseMessageContext(messageStatus));

      const wrapper = mountComponent();

      expect(
        wrapper.findComponent({ name: 'MessageStatus' }).props('status')
      ).toBe(expectedStatus);
    }
  );
});
