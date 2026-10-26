import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { ref } from 'vue';

import inboxes from 'dashboard/store/modules/inboxes';
import { REPLY_EDITOR_MODES } from 'dashboard/components/widgets/WootWriter/constants';
import en from 'dashboard/i18n/locale/en/conversation.json';
import enTemplates from 'dashboard/i18n/locale/en/whatsappTemplates.json';
import ReplyBox from './ReplyBox.vue';

const FOOTER = en.CONVERSATION.FOOTER;
const PICKER = enTemplates.WHATSAPP_TEMPLATES.PICKER;

// A plain button that renders its label, icon and type: the global NextButton
// stub drops them.
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
const ContentTemplatesStub = {
  props: ['show'],
  template: '<div data-test="content-templates" :data-show="String(show)" />',
};

const mockChat = ref(null);
// every message the reply box tries to send ends up here
const sendMessageAction = vi.fn(() => Promise.resolve({}));

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

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    processEvent: vi.fn(),
    followUp: vi.fn(),
    currentChat: mockChat,
    conversationId: ref(42),
    captainTextImprovementEnabled: ref(true),
    startReplySuggestion: vi.fn(),
    getReplySuggestionStatus: vi.fn(() =>
      Promise.resolve({ suggestion: null })
    ),
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

const INBOX_ID = 272;

const template = (name, status) => ({
  name,
  language: 'ru',
  status,
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
});

// The production case: three templates, all still waiting for WhatsApp.
const THREE_PENDING = [
  template('reminder_24h', 'PENDING'),
  template('reminder_2h', 'PENDING'),
  template('hello', 'PENDING'),
];

const CLOUD_INBOX = {
  id: INBOX_ID,
  channel_type: 'Channel::Whatsapp',
  provider: 'whatsapp_cloud',
};
const TWILIO_INBOX = {
  id: INBOX_ID,
  channel_type: 'Channel::TwilioSms',
  medium: 'whatsapp',
  content_templates: { templates: [] },
};
const WEB_INBOX = { id: INBOX_ID, channel_type: 'Channel::WebWidget' };
const API_INBOX = { id: INBOX_ID, channel_type: 'Channel::Api' };
// 360dialog is the WhatsApp provider called «default»
const DIALOG_360_INBOX = {
  id: INBOX_ID,
  channel_type: 'Channel::Whatsapp',
  provider: 'default',
};
const INSTAGRAM_INBOX_ID = 300;
const INSTAGRAM_INBOX = {
  id: INSTAGRAM_INBOX_ID,
  channel_type: 'Channel::Instagram',
};

const chatOf = canReply => ({
  id: 42,
  inbox_id: INBOX_ID,
  can_reply: canReply,
  meta: { sender: { id: 5 } },
  additional_attributes: {},
});

const buildStore = (inbox, messageTemplates, otherInboxes = []) =>
  createStore({
    getters: {
      getSelectedChat: () => mockChat.value,
      getMessageSignature: () => '',
      getCurrentUser: () => ({ id: 7, name: 'Менеджер' }),
      getLastEmailInSelectedChat: () => null,
      getConversationById: () => () => null,
      getCurrentRole: () => 'administrator',
      'globalConfig/get': () => ({}),
      getCurrentAccountId: () => 97,
      'accounts/isFeatureEnabledonAccount': () => () => true,
      'integrations/getUIFlags': () => ({}),
      'contacts/getContact': () => () => ({ id: 5 }),
      'draftMessages/get': () => () => '',
      'draftMessages/getReplyEditorMode': () => 'reply',
      'attributes/getAttributesByModel': () => () => [],
    },
    actions: {
      'draftMessages/setReplyEditorMode': vi.fn(),
      'draftMessages/set': vi.fn(),
      'draftMessages/delete': vi.fn(),
      'draftMessages/get': vi.fn(),
      createPendingMessageAndSend: sendMessageAction,
    },
    modules: {
      // the real inboxes module: which templates are sendable is its rule
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [
            { ...inbox, message_templates: messageTemplates },
            ...otherInboxes,
          ],
        }),
      },
    },
  });

const mountReplyBox = async ({
  inbox = CLOUD_INBOX,
  canReply = false,
  messageTemplates = [],
  chat = chatOf(canReply),
  otherInboxes = [],
} = {}) => {
  mockChat.value = chat;
  const wrapper = shallowMount(ReplyBox, {
    attachTo: document.body,
    global: {
      plugins: [buildStore(inbox, messageTemplates, otherInboxes)],
      directives: { 'on-clickaway': {} },
      stubs: {
        NextButton: NextButtonStub,
        Icon: true,
        transition: PassThroughStub,
        Transition: PassThroughStub,
        WootMessageEditor: MessageEditorStub,
        ContentTemplates: ContentTemplatesStub,
        // the real send panel, template modal, list and empty state
        ReplyBottomPanel: false,
        WhatsappTemplates: false,
        TemplatesPicker: false,
        TemplatesEmptyState: false,
        'woot-confirm-modal': true,
      },
    },
  });
  await flushPromises();
  return wrapper;
};

const find = selector => document.body.querySelector(selector);
const calmLine = () => find('[data-test-id="whatsapp-template-only-notice"]');
const editor = () => find('[data-test="message-editor"]');
const templateButton = () => find('[data-test-id="reply-template-button"]');
const sendButton = () => find('button[type="submit"]');
// the small icon button of the left side, shown while the window is open
const iconTemplateButton = () =>
  find('button[data-icon="i-ph-whatsapp-logo"]:not([data-test-id])');
const emptyState = () => find('[data-test-id="whatsapp-templates-empty"]');

describe('ReplyBox with a closed WhatsApp window', () => {
  let wrapper;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
  });

  describe('WhatsApp Cloud, nothing approved yet', () => {
    it('explains the closed window and offers the template button', async () => {
      wrapper = await mountReplyBox({ messageTemplates: THREE_PENDING });

      expect(calmLine().textContent).toContain(FOOTER.WHATSAPP_TEMPLATE_ONLY);
      expect(editor()).toBeNull();
      expect(templateButton()).not.toBeNull();
      expect(templateButton().textContent).toContain(FOOTER.TEMPLATE_BUTTON);
      expect(templateButton().disabled).toBe(false);
      // no dead «send» left next to it
      expect(sendButton()).toBeNull();
    });

    it('opens the list with a plain empty state and the review count', async () => {
      wrapper = await mountReplyBox({ messageTemplates: THREE_PENDING });
      expect(wrapper.vm.showWhatsAppTemplatesModal).toBe(false);

      templateButton().click();
      await flushPromises();

      expect(wrapper.vm.showWhatsAppTemplatesModal).toBe(true);
      expect(emptyState().textContent).toContain(PICKER.NO_APPROVED_TEMPLATES);
      expect(emptyState().textContent).toContain(
        PICKER.TEMPLATES_IN_REVIEW.replace('{count}', '3')
      );
      // not one of the waiting templates is offered for sending
      expect(document.body.textContent).not.toContain('reminder_24h');
      expect(document.body.textContent).not.toContain('hello');
      expect(
        find('[data-test-id="whatsapp-templates-settings-link"]').getAttribute(
          'href'
        )
      ).toBe('/app/accounts/97/settings/inboxes/272/whatsapp-templates');
    });

    it('also holds when the template list was never loaded', async () => {
      wrapper = await mountReplyBox({ messageTemplates: undefined });

      expect(calmLine()).not.toBeNull();
      expect(templateButton()).not.toBeNull();
    });
  });

  describe('WhatsApp Cloud, some templates approved', () => {
    it('lists only the approved ones', async () => {
      wrapper = await mountReplyBox({
        messageTemplates: [
          template('order_update', 'APPROVED'),
          template('reminder_24h', 'PENDING'),
          template('old_offer', 'REJECTED'),
        ],
      });

      expect(calmLine()).not.toBeNull();
      expect(templateButton()).not.toBeNull();

      templateButton().click();
      await flushPromises();

      expect(emptyState()).toBeNull();
      expect(document.body.textContent).toContain('order_update');
      expect(document.body.textContent).not.toContain('reminder_24h');
      expect(document.body.textContent).not.toContain('old_offer');
    });
  });

  describe('Twilio WhatsApp', () => {
    it('shows the same line and a template button for its own templates', async () => {
      wrapper = await mountReplyBox({ inbox: TWILIO_INBOX });

      expect(calmLine().textContent).toContain(FOOTER.WHATSAPP_TEMPLATE_ONLY);
      expect(editor()).toBeNull();
      expect(templateButton().textContent).toContain(FOOTER.TEMPLATE_BUTTON);
      expect(sendButton()).toBeNull();
      // one template button, not a second one for the WhatsApp Cloud list
      expect(
        document.body.querySelectorAll('button[data-icon="i-ph-whatsapp-logo"]')
      ).toHaveLength(1);

      templateButton().click();
      await flushPromises();

      expect(wrapper.vm.showContentTemplatesModal).toBe(true);
      expect(wrapper.vm.showWhatsAppTemplatesModal).toBe(false);
    });
  });

  describe('360dialog WhatsApp', () => {
    it('shows the line, the button and the empty state, with no settings link', async () => {
      wrapper = await mountReplyBox({
        inbox: DIALOG_360_INBOX,
        messageTemplates: THREE_PENDING,
      });

      expect(calmLine().textContent).toContain(FOOTER.WHATSAPP_TEMPLATE_ONLY);
      expect(editor()).toBeNull();
      expect(templateButton().textContent).toContain(FOOTER.TEMPLATE_BUTTON);
      expect(sendButton()).toBeNull();

      templateButton().click();
      await flushPromises();

      expect(wrapper.vm.showWhatsAppTemplatesModal).toBe(true);
      expect(emptyState().textContent).toContain(PICKER.NO_APPROVED_TEMPLATES);
      expect(emptyState().textContent).toContain(
        PICKER.TEMPLATES_IN_REVIEW.replace('{count}', '3')
      );
      // the templates page exists only for WhatsApp Cloud inboxes
      expect(
        find('[data-test-id="whatsapp-templates-settings-link"]')
      ).toBeNull();
    });
  });

  describe('approved templates that a conversation cannot send', () => {
    it('does not say that nothing is approved', async () => {
      wrapper = await mountReplyBox({
        messageTemplates: [
          {
            ...template('hidden_offer', 'APPROVED'),
            visible_in_conversation_picker: false,
          },
          template('reminder_24h', 'PENDING'),
        ],
      });

      templateButton().click();
      await flushPromises();

      expect(emptyState().textContent).toContain(PICKER.NO_TEMPLATES_TO_SEND);
      expect(emptyState().textContent).not.toContain(
        PICKER.NO_APPROVED_TEMPLATES
      );
      expect(document.body.textContent).not.toContain('hidden_offer');
    });
  });

  describe('a multi-channel dialog', () => {
    // WhatsApp needs a template; Instagram next to it can still take text
    const threadChat = {
      id: 42,
      inbox_id: INBOX_ID,
      is_communication_thread: true,
      communication_thread_id: 'thread-1',
      can_reply: true,
      meta: { sender: { id: 5 } },
      additional_attributes: {},
      messages: [],
      channels: [
        {
          channel: 'Channel::Whatsapp',
          inbox_id: INBOX_ID,
          conversation_id: 42,
          can_reply: false,
          can_send_text: false,
          requires_template: true,
        },
        {
          channel: 'Channel::Instagram',
          inbox_id: INSTAGRAM_INBOX_ID,
          conversation_id: 43,
          can_reply: true,
          can_send_text: true,
        },
      ],
    };
    const mountThread = async selectedConversationId => {
      const mounted = await mountReplyBox({
        chat: threadChat,
        messageTemplates: THREE_PENDING,
        otherInboxes: [INSTAGRAM_INBOX],
      });
      await mounted.setData({
        selectedReplyConversationId: selectedConversationId,
      });
      await flushPromises();
      return mounted;
    };

    it('asks for a template on the WhatsApp channel and keeps the channel menu', async () => {
      wrapper = await mountThread('42');

      expect(calmLine()).not.toBeNull();
      expect(editor()).toBeNull();
      expect(templateButton()).not.toBeNull();
      expect(sendButton()).toBeNull();
      // the menu to switch to Instagram stays attached to the button
      expect(find('.reply-channel-menu__toggle')).not.toBeNull();

      templateButton().click();
      await flushPromises();

      expect(wrapper.vm.showWhatsAppTemplatesModal).toBe(true);
      expect(emptyState().textContent).toContain(PICKER.NO_APPROVED_TEMPLATES);
    });

    it('lets the agent write freely on the open Instagram channel', async () => {
      wrapper = await mountThread('43');

      expect(calmLine()).toBeNull();
      expect(editor()).not.toBeNull();
      expect(templateButton()).toBeNull();
      expect(sendButton()).not.toBeNull();
      expect(find('.reply-channel-menu__toggle')).not.toBeNull();
    });
  });

  describe('sending while only a template is allowed', () => {
    it('does not send typed text', async () => {
      wrapper = await mountReplyBox({ messageTemplates: THREE_PENDING });
      await wrapper.setData({ message: 'Здравствуйте!' });

      await wrapper.vm.onSendReply();
      await flushPromises();

      expect(sendMessageAction).not.toHaveBeenCalled();
    });

    it('does not send an attachment', async () => {
      wrapper = await mountReplyBox({ messageTemplates: THREE_PENDING });
      await wrapper.setData({
        attachedFiles: [
          { currentChatId: 42, resource: {}, isPrivate: false, thumb: '' },
        ],
      });

      await wrapper.vm.onSendReply();
      await flushPromises();

      expect(sendMessageAction).not.toHaveBeenCalled();
    });

    // the control: the same steps do reach the send action once the window is
    // open, so the two tests above fail for the right reason
    it('does send typed text when the window is open', async () => {
      wrapper = await mountReplyBox({ canReply: true });
      await wrapper.setData({ message: 'Здравствуйте!' });

      await wrapper.vm.onSendReply();
      await flushPromises();

      expect(sendMessageAction).toHaveBeenCalledTimes(1);
    });

    it('still sends the template the agent chose', async () => {
      wrapper = await mountReplyBox({
        messageTemplates: [template('order_update', 'APPROVED')],
      });

      await wrapper.vm.onSendWhatsAppReply({
        message: 'order_update body',
        templateParams: { name: 'order_update', language: 'ru' },
      });
      await flushPromises();

      expect(sendMessageAction).toHaveBeenCalledTimes(1);
      expect(sendMessageAction.mock.calls[0][1]).toMatchObject({
        conversationId: 42,
        message: 'order_update body',
      });
    });
  });

  describe('the note tab', () => {
    it('keeps the editor for an internal note', async () => {
      wrapper = await mountReplyBox({ messageTemplates: THREE_PENDING });
      expect(calmLine()).not.toBeNull();

      await wrapper.setData({ replyType: REPLY_EDITOR_MODES.NOTE });

      expect(calmLine()).toBeNull();
      expect(editor()).not.toBeNull();
      expect(templateButton()).toBeNull();
      expect(sendButton()).not.toBeNull();
    });
  });

  describe('an open window', () => {
    it('is unchanged: editor and send, no line, no template button without templates', async () => {
      wrapper = await mountReplyBox({ canReply: true });

      expect(calmLine()).toBeNull();
      expect(editor()).not.toBeNull();
      expect(sendButton()).not.toBeNull();
      expect(templateButton()).toBeNull();
      expect(iconTemplateButton()).toBeNull();
    });

    it('is unchanged: the small template button appears with an approved template', async () => {
      wrapper = await mountReplyBox({
        canReply: true,
        messageTemplates: [template('order_update', 'APPROVED')],
      });

      expect(calmLine()).toBeNull();
      expect(editor()).not.toBeNull();
      expect(sendButton()).not.toBeNull();
      expect(templateButton()).toBeNull();
      expect(iconTemplateButton()).not.toBeNull();
      expect(iconTemplateButton().textContent.trim()).toBe('');
    });

    it('does not offer the template button for templates still in review', async () => {
      wrapper = await mountReplyBox({
        canReply: true,
        messageTemplates: THREE_PENDING,
      });

      expect(iconTemplateButton()).toBeNull();
      expect(templateButton()).toBeNull();
    });
  });

  describe('a channel that is not WhatsApp', () => {
    it('keeps the web widget reply box as it was', async () => {
      wrapper = await mountReplyBox({ inbox: WEB_INBOX, canReply: true });

      expect(calmLine()).toBeNull();
      expect(editor()).not.toBeNull();
      expect(sendButton()).not.toBeNull();
      expect(templateButton()).toBeNull();
      expect(iconTemplateButton()).toBeNull();
    });

    it.each([
      ['Instagram', INSTAGRAM_INBOX],
      ['Facebook', { channel_type: 'Channel::FacebookPage' }],
      ['Telegram', { channel_type: 'Channel::Telegram' }],
    ])(
      'does not turn a closed %s window into a template-only reply box',
      async (_name, inbox) => {
        wrapper = await mountReplyBox({
          inbox: { ...inbox, id: INBOX_ID },
          canReply: false,
          messageTemplates: THREE_PENDING,
        });

        expect(calmLine()).toBeNull();
        expect(templateButton()).toBeNull();
        expect(iconTemplateButton()).toBeNull();
        expect(editor()).not.toBeNull();
      }
    );

    it('keeps WhatsApp Web (personal) as it was, with a closed window', async () => {
      wrapper = await mountReplyBox({
        inbox: { id: INBOX_ID, channel_type: 'Channel::WhatsappWeb' },
        canReply: false,
        messageTemplates: THREE_PENDING,
      });

      expect(calmLine()).toBeNull();
      expect(templateButton()).toBeNull();
      expect(editor()).not.toBeNull();
    });

    it('keeps the disabled editor of an API inbox with a closed window', async () => {
      wrapper = await mountReplyBox({ inbox: API_INBOX, canReply: false });

      expect(wrapper.vm.isEditorDisabled).toBe(true);
      expect(calmLine()).toBeNull();
      expect(editor()).not.toBeNull();
      expect(templateButton()).toBeNull();
      expect(sendButton()).not.toBeNull();
    });
  });
});
