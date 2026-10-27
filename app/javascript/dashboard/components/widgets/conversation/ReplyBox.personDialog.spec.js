import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { nextTick, reactive, ref } from 'vue';

import inboxes from 'dashboard/store/modules/inboxes';
import { useAlert } from 'dashboard/composables';
import en from 'dashboard/i18n/locale/en/conversation.json';
import enTemplates from 'dashboard/i18n/locale/en/whatsappTemplates.json';
import { buildPersonDialogChat } from 'dashboard/helper/communicationThreadHelper';
import ReplyBox from './ReplyBox.vue';

const FOOTER = en.CONVERSATION.FOOTER;
const ERRORS = en.PERSON_DIALOG.ERRORS;
const PICKER = enTemplates.WHATSAPP_TEMPLATES.PICKER;

const NextButtonStub = {
  inheritAttrs: false,
  props: ['label', 'icon', 'disabled', 'type'],
  emits: ['click'],
  template: `<button
    v-bind="$attrs"
    :type="type || 'button'"
    :data-icon="icon"
    :disabled="disabled"
    @click="$emit('click')"
  >{{ label }}</button>`,
};
const PassThroughStub = { inheritAttrs: false, template: '<slot />' };
const MessageEditorStub = { template: '<div data-test="message-editor" />' };

const mockChat = ref(null);
const sendMessageAction = vi.fn(() => Promise.resolve({}));
const promotePersonDialog = vi.fn();
const deleteDraft = vi.fn();

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

// The suggestion machinery asks the server about a conversation: it must not be asked about a person who has none.
const getReplySuggestionStatus = vi.fn(() =>
  Promise.resolve({ suggestion: null })
);
vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    processEvent: vi.fn(),
    followUp: vi.fn(),
    currentChat: mockChat,
    conversationId: ref(null),
    captainTextImprovementEnabled: ref(true),
    startReplySuggestion: vi.fn(),
    getReplySuggestionStatus,
    cancelReplySuggestion: vi.fn(),
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

vi.mock('dashboard/api/captain/tasks', () => ({
  default: {
    feedback: vi.fn(() => Promise.resolve()),
    approveAction: vi.fn(),
    rejectAction: vi.fn(),
  },
}));

const WHATSAPP_INBOX_ID = 12;
const WHATSAPP_INBOX = {
  id: WHATSAPP_INBOX_ID,
  channel_type: 'Channel::Whatsapp',
  provider: 'whatsapp_cloud',
};

const whatsappChannel = {
  conversation_id: null,
  inbox_id: WHATSAPP_INBOX_ID,
  inbox_name: 'WhatsApp',
  channel: 'Channel::Whatsapp',
  channel_key: 'inbox:12',
  requires_template: true,
  can_reply: false,
  can_send_text: false,
};

const draftChat = (channels = [whatsappChannel], extra = {}) => ({
  ...buildPersonDialogChat({
    contactId: 5,
    contact: { id: 5, name: 'Aigul', phone_number: '+77011234567' },
    channels,
    messages: [],
    ...extra,
  }),
});

const buildStore = (dispatched = []) =>
  createStore({
    getters: {
      getSelectedChat: () => mockChat.value,
      getMessageSignature: () => '',
      getCurrentUser: () => ({ id: 7, name: 'Manager' }),
      getLastEmailInSelectedChat: () => null,
      getConversationById: () => () => null,
      getCurrentRole: () => 'administrator',
      'globalConfig/get': () => ({}),
      getCurrentAccountId: () => 97,
      'accounts/isFeatureEnabledonAccount': () => () => true,
      'integrations/getUIFlags': () => ({}),
      'contacts/getContact': () => () => ({ id: 5, phone_number: '+7701' }),
      'draftMessages/get': () => () => '',
      'draftMessages/getReplyEditorMode': () => 'reply',
      'attributes/getAttributesByModel': () => () => [],
    },
    actions: {
      'draftMessages/setReplyEditorMode': vi.fn(),
      'draftMessages/set': vi.fn(),
      'draftMessages/delete': (_context, payload) => {
        dispatched.push(payload.key);
        deleteDraft(payload);
      },
      'draftMessages/get': vi.fn(),
      createPendingMessageAndSend: sendMessageAction,
      promotePersonDialog,
    },
    modules: {
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [{ ...WHATSAPP_INBOX, message_templates: [] }],
        }),
      },
    },
  });

const mountReplyBox = async ({
  chat = draftChat(),
  replyChannelState,
} = {}) => {
  mockChat.value = chat;
  const dispatched = [];
  const wrapper = shallowMount(ReplyBox, {
    attachTo: document.body,
    global: {
      plugins: [buildStore(dispatched)],
      directives: { 'on-clickaway': {} },
      provide: replyChannelState ? { replyChannelState } : {},
      stubs: {
        NextButton: NextButtonStub,
        Icon: true,
        transition: PassThroughStub,
        Transition: PassThroughStub,
        WootMessageEditor: MessageEditorStub,
        ReplyBottomPanel: false,
        WhatsappTemplates: false,
        TemplatesPicker: false,
        TemplatesEmptyState: false,
        'woot-confirm-modal': true,
      },
    },
  });
  await flushPromises();
  wrapper.dispatchedDraftKeys = dispatched;
  return wrapper;
};

const find = selector => document.body.querySelector(selector);

describe('ReplyBox in the empty dialog of a person', () => {
  let wrapper;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
  });

  it('is a draft with no conversation of its own: nothing carries the screen id', async () => {
    wrapper = await mountReplyBox();

    expect(wrapper.vm.isDraft).toBe(true);
    expect(wrapper.vm.conversationId).toBeNull();
    expect(wrapper.vm.isCommunicationThreadConversation).toBe(true);
  });

  it('does not ask the server for a suggestion of a conversation that does not exist', async () => {
    wrapper = await mountReplyBox();

    expect(getReplySuggestionStatus).not.toHaveBeenCalled();
  });

  it('hides the AI helpers that work on a conversation', async () => {
    wrapper = await mountReplyBox();

    expect(
      wrapper
        .findComponent({ name: 'ReplyTopPanel' })
        .props('showCopilotActions')
    ).toBe(false);
  });

  it('keeps the note tab', async () => {
    wrapper = await mountReplyBox();

    expect(wrapper.findComponent({ name: 'ReplyTopPanel' }).exists()).toBe(
      true
    );
    expect(wrapper.vm.setReplyMode).toBeTypeOf('function');
  });

  it('opens with WhatsApp and the template button when the person has never written', async () => {
    wrapper = await mountReplyBox();

    expect(wrapper.vm.activeReplyChannel.channel_key).toBe('inbox:12');
    expect(find('[data-test-id="reply-template-button"]')).not.toBeNull();
    expect(find('[data-test="message-editor"]')).toBeNull();
    expect(
      find('[data-test-id="whatsapp-template-only-notice"]').textContent
    ).toContain(FOOTER.WHATSAPP_TEMPLATE_ONLY);
  });

  it('lists the approved templates of the channel', async () => {
    wrapper = await mountReplyBox();

    find('[data-test-id="reply-template-button"]').click();
    await flushPromises();

    expect(wrapper.vm.showWhatsAppTemplatesModal).toBe(true);
    expect(
      find('[data-test-id="whatsapp-templates-empty"]').textContent
    ).toContain(PICKER.NO_APPROVED_TEMPLATES);
  });

  it('sends the first message to the person, through the selected channel, not to a conversation', async () => {
    wrapper = await mountReplyBox({
      chat: draftChat([
        {
          ...whatsappChannel,
          requires_template: false,
          can_reply: true,
          can_send_text: true,
        },
      ]),
    });

    await wrapper.vm.sendMessage({ message: 'Hello', private: false });

    const payload = sendMessageAction.mock.calls[0][1];
    expect(payload).toMatchObject({
      message: 'Hello',
      person_contact_id: 5,
      channelKey: 'inbox:12',
      targetInboxId: WHATSAPP_INBOX_ID,
    });
    expect(payload.conversationId).toBeUndefined();
    expect(payload.communicationThreadId).toBeUndefined();
  });

  it('sends a note the same way: the first note makes the dialog', async () => {
    wrapper = await mountReplyBox();

    await wrapper.vm.sendMessage({ message: 'Call back', private: true });

    expect(sendMessageAction.mock.calls[0][1]).toMatchObject({
      message: 'Call back',
      private: true,
      person_contact_id: 5,
    });
  });

  it.each([
    ['template_required', ERRORS.template_required],
    ['contact_blocked', ERRORS.contact_blocked],
    ['channel_unavailable', ERRORS.channel_unavailable],
  ])('says %s in plain words', async (code, text) => {
    sendMessageAction.mockRejectedValueOnce({
      response: { data: { code, error: 'technical text' } },
    });
    wrapper = await mountReplyBox();

    await wrapper.vm.sendMessage({ message: 'Hello', private: false });

    expect(useAlert).toHaveBeenCalledWith(text);
  });

  it('names the other contact when the number is theirs', async () => {
    sendMessageAction.mockRejectedValueOnce({
      response: {
        data: {
          code: 'foreign_chat_identity',
          error: 'technical text',
          details: { contact_name: 'Nurlan' },
        },
      },
    });
    wrapper = await mountReplyBox();

    await wrapper.vm.sendMessage({ message: 'Hello', private: false });

    expect(useAlert).toHaveBeenCalledWith(
      ERRORS.foreign_chat_identity.replace('{name}', 'Nurlan')
    );
  });

  it('falls back to the message of the server for an error it has no words for', async () => {
    sendMessageAction.mockRejectedValueOnce({
      response: { data: { error: 'Something odd' } },
    });
    wrapper = await mountReplyBox();

    await wrapper.vm.sendMessage({ message: 'Hello', private: false });

    expect(useAlert).toHaveBeenCalledWith('Something odd');
  });

  it('turns the draft into the dialog of a call started from the box', async () => {
    wrapper = await mountReplyBox();

    wrapper.vm.onCallInitiated({ communication_thread_id: 77 });

    expect(promotePersonDialog).toHaveBeenCalledWith(expect.anything(), {
      contactId: 5,
      communicationThreadId: 77,
    });
  });

  it('keeps what is typed when the first message made the dialog, and drops the stored text of the draft', async () => {
    wrapper = await mountReplyBox();
    wrapper.vm.message = 'typed while the dialog appeared';

    mockChat.value = {
      id: 77,
      is_communication_thread: true,
      contact_id: 5,
      meta: { sender: { id: 5 } },
      channels: [
        {
          ...whatsappChannel,
          conversation_id: 301,
          channel_key: 'conversation:301',
        },
      ],
      messages: [],
    };
    await nextTick();
    await flushPromises();

    expect(wrapper.vm.message).toBe('typed while the dialog appeared');
    expect(wrapper.dispatchedDraftKeys).toEqual(
      expect.arrayContaining(['draft-draft-5-REPLY', 'draft-draft-5-NOTE'])
    );
  });

  it('tells the empty screen which channel is selected', async () => {
    const replyChannelState = reactive({ key: null });
    wrapper = await mountReplyBox({
      chat: draftChat([
        whatsappChannel,
        {
          conversation_id: null,
          inbox_id: 13,
          inbox_name: 'SMS',
          channel: 'Channel::Sms',
          channel_key: 'inbox:13',
          can_reply: true,
          can_send_text: true,
        },
      ]),
      replyChannelState,
    });

    wrapper.vm.selectReplyChannel('inbox:13');
    await nextTick();

    expect(replyChannelState.key).toBe('inbox:13');
  });
});
