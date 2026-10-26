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

const chatOf = canReply => ({
  id: 42,
  inbox_id: INBOX_ID,
  can_reply: canReply,
  meta: { sender: { id: 5 } },
  additional_attributes: {},
});

const buildStore = (inbox, messageTemplates) =>
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
    },
    modules: {
      // the real inboxes module: which templates are sendable is its rule
      inboxes: {
        ...inboxes,
        state: () => ({
          ...(typeof inboxes.state === 'function'
            ? inboxes.state()
            : inboxes.state),
          records: [{ ...inbox, message_templates: messageTemplates }],
        }),
      },
    },
  });

const mountReplyBox = async ({
  inbox = CLOUD_INBOX,
  canReply = false,
  messageTemplates = [],
} = {}) => {
  mockChat.value = chatOf(canReply);
  const wrapper = shallowMount(ReplyBox, {
    attachTo: document.body,
    global: {
      plugins: [buildStore(inbox, messageTemplates)],
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
