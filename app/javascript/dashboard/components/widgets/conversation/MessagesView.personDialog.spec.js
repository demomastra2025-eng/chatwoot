import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { ref } from 'vue';

import inboxes from 'dashboard/store/modules/inboxes';
import { buildPersonDialogChat } from 'dashboard/helper/communicationThreadHelper';
import MessagesView from './MessagesView.vue';
import ReplyBox from './ReplyBox.vue';

// Every request the screen makes. The empty dialog of a person exists only in the screen, so it makes none that names a
// conversation or a thread.
const requests = [];
const record =
  method =>
  (url, ...rest) => {
    requests.push([method, typeof url === 'string' ? url : url?.url]);
    return Promise.resolve({ data: { payload: [], meta: {} }, rest });
  };
const axiosMock = Object.assign(
  vi.fn(config => {
    requests.push([config?.method || 'request', config?.url]);
    return Promise.resolve({ data: {} });
  }),
  {
    get: vi.fn(record('get')),
    post: vi.fn(record('post')),
    patch: vi.fn(record('patch')),
    put: vi.fn(record('put')),
    delete: vi.fn(record('delete')),
  }
);

const mockChat = ref(null);

vi.mock('activestorage', () => ({ start: vi.fn() }));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('dashboard/composables/useWhatsappCallInitiation', () => ({
  useWhatsappCallInitiation: () => ({
    canInitiateWhatsappCall: false,
    initiateWhatsappCall: vi.fn(),
    isInitiatingWhatsappCall: false,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: ref({}),
    isEditorHotKeyEnabled: () => true,
    fetchSignatureFlagFromUISettings: () => false,
    setQuotedReplyFlagForInbox: vi.fn(),
    fetchQuotedReplyFlagFromUISettings: () => false,
  }),
}));

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    processEvent: vi.fn(),
    followUp: vi.fn(),
    currentChat: mockChat,
    conversationId: ref(null),
    captainTextImprovementEnabled: ref(false),
    startReplySuggestion: vi.fn(),
    getReplySuggestionStatus: vi.fn(() => {
      requests.push(['get', 'reply_suggestion_status']);
      return Promise.resolve({ suggestion: null });
    }),
    cancelReplySuggestion: vi.fn(),
  }),
}));

vi.mock('dashboard/api/captain/tasks', () => ({
  default: {
    feedback: vi.fn(() => Promise.resolve()),
    approveAction: vi.fn(),
    rejectAction: vi.fn(),
    labelSuggestion: vi.fn(() => {
      requests.push(['post', 'label_suggestion']);
      return Promise.resolve({ data: { message: '' } });
    }),
  },
}));

const PassThroughStub = { inheritAttrs: false, template: '<slot />' };
const NextButtonStub = {
  inheritAttrs: false,
  props: ['label', 'icon', 'disabled', 'type'],
  emits: ['click'],
  template: `<button v-bind="$attrs" :type="type || 'button'" :disabled="disabled" @click="$emit('click')">{{ label }}</button>`,
};

const WHATSAPP_INBOX = {
  id: 12,
  channel_type: 'Channel::Whatsapp',
  provider: 'whatsapp_cloud',
  message_templates: [],
};
const whatsappChannel = {
  conversation_id: null,
  inbox_id: 12,
  inbox_name: 'WhatsApp',
  channel: 'Channel::Whatsapp',
  channel_key: 'inbox:12',
  requires_template: true,
  can_reply: false,
  can_send_text: false,
};

const buildStore = () =>
  createStore({
    getters: {
      getSelectedChat: () => mockChat.value,
      getAllMessagesLoaded: () => true,
      getCurrentUserID: () => 7,
      getCurrentUser: () => ({ id: 7, name: 'Manager', accounts: [] }),
      getCurrentAccountId: () => 97,
      getMessageSignature: () => '',
      getLastEmailInSelectedChat: () => null,
      getConversationById: () => () => null,
      getCurrentRole: () => 'administrator',
      'globalConfig/get': () => ({}),
      'accounts/isFeatureEnabledonAccount': () => () => true,
      'integrations/getUIFlags': () => ({}),
      'contacts/getContact': () => () => ({ id: 5, phone_number: '+7701' }),
      'draftMessages/get': () => () => '',
      'draftMessages/getReplyEditorMode': () => 'reply',
      'attributes/getAttributesByModel': () => () => [],
      'conversationTypingStatus/getUserList': () => () => [],
      'inboxes/getInstagramInboxByInstagramId': () => () => null,
    },
    actions: {
      'draftMessages/setReplyEditorMode': vi.fn(),
      'draftMessages/set': vi.fn(),
      'draftMessages/delete': vi.fn(),
      'draftMessages/get': vi.fn(),
      'conversationTypingStatus/toggleTyping': () => {
        requests.push(['post', 'toggle_typing_status']);
      },
      markMessagesRead: () => {
        requests.push(['post', 'update_last_seen']);
      },
      markCommunicationThreadRead: () => {
        requests.push(['post', 'communication_threads/update_last_seen']);
      },
      fetchPreviousMessages: () => {
        requests.push(['get', 'messages']);
      },
      fetchAllAttachments: () => {
        requests.push(['get', 'attachments']);
      },
    },
    modules: {
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [WHATSAPP_INBOX],
        }),
      },
    },
  });

const draftChat = () =>
  buildPersonDialogChat({
    contactId: 5,
    contact: { id: 5, name: 'Aigul', phone_number: '+77011234567' },
    channels: [whatsappChannel],
    messages: [],
  });

describe('MessagesView with the empty dialog of a person', () => {
  let wrapper;
  const originalAxios = window.axios;

  beforeEach(() => {
    requests.length = 0;
    window.axios = axiosMock;
    mockChat.value = draftChat();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    window.axios = originalAxios;
  });

  const mountView = async () => {
    wrapper = mount(MessagesView, {
      attachTo: document.body,
      global: {
        plugins: [buildStore()],
        directives: { 'on-clickaway': {}, tooltip: {} },
        stubs: {
          NextButton: NextButtonStub,
          Icon: true,
          transition: PassThroughStub,
          Transition: PassThroughStub,
          WootMessageEditor: { template: '<div data-test="message-editor" />' },
          ResizableEditorWrapper: PassThroughStub,
          CallOperatorIndicator: true,
          Banner: true,
          MessageList: {
            props: ['messages'],
            template:
              '<ul data-test="message-list"><slot name="beforeAll" /><slot name="after" /></ul>',
          },
          IntersectionObserver: true,
          'woot-confirm-modal': true,
        },
      },
    });
    await flushPromises();
  };

  it('makes no request that names a conversation or a thread, and says what the first message needs', async () => {
    await mountView();

    const named = requests.filter(([, url]) =>
      /conversations|communication_threads|messages|attachments|update_last_seen|toggle_typing|reply_suggestion|label_suggestion/.test(
        String(url)
      )
    );
    expect(named).toEqual([]);
    expect(
      document.body.querySelector('[data-test-id="person-dialog-empty-state"]')
    ).not.toBeNull();
  });

  it('makes no request when the person is typed to, either', async () => {
    await mountView();

    const replyBox = wrapper.findComponent(ReplyBox);
    expect(replyBox.exists()).toBe(true);
    replyBox.vm.onTypingOn();
    await flushPromises();

    expect(
      requests.filter(([, url]) => /toggle_typing/.test(String(url)))
    ).toEqual([]);
  });
});
