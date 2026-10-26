import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { ref } from 'vue';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import TasksAPI from 'dashboard/api/captain/tasks';
import en from 'dashboard/i18n/locale/en/conversation.json';
import ReplyBox from './ReplyBox.vue';

const LABELS = en.CONVERSATION.REPLYBOX.COPILOT_SUGGESTION;

// A plain button that renders the label: the global NextButton stub drops it
const NextButtonStub = {
  props: ['label'],
  template: '<button type="button">{{ label }}</button>',
};

// Stand-ins for the heavy children. They keep the props ReplyBox passes and
// the events it listens to, so the wiring of the reply box is what is tested.
const CopilotReplyBottomPanelStub = {
  props: ['isGeneratingContent', 'isGenerating', 'canCancel'],
  emits: ['submit', 'cancel', 'reject'],
  template: `<div
    data-test="copilot-panel"
    :data-generating="String(isGenerating)"
    :data-can-cancel="String(canCancel)"
  >
    <button data-test="panel-cancel" @click="$emit('cancel')" />
    <button data-test="panel-reject" @click="$emit('reject')" />
    <button data-test="panel-submit" @click="$emit('submit')" />
  </div>`,
};
const CopilotEditorSectionStub = {
  props: ['generatedContent', 'stale', 'engine', 'isQueued'],
  template:
    '<div data-test="copilot-section" :data-queued="String(isQueued)" :data-stale="String(stale)">{{ generatedContent }}</div>',
};
const PassThroughStub = { inheritAttrs: false, template: '<slot />' };
const MessageEditorStub = { template: '<div data-test="message-editor" />' };
const ReplyBottomPanelStub = { template: '<div data-test="reply-panel" />' };

const mockChat = ref(null);
const mockConversationId = ref(42);
const mockStartReplySuggestion = vi.fn();
const mockGetReplySuggestionStatus = vi.fn();
const mockCancelReplySuggestion = vi.fn();

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    processEvent: vi.fn(),
    followUp: vi.fn(),
    currentChat: mockChat,
    conversationId: mockConversationId,
    captainTextImprovementEnabled: ref(true),
    startReplySuggestion: mockStartReplySuggestion,
    getReplySuggestionStatus: mockGetReplySuggestionStatus,
    cancelReplySuggestion: mockCancelReplySuggestion,
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

const chatOf = id => ({
  id,
  inbox_id: 1,
  can_reply: true,
  meta: { sender: { id: 5 } },
  additional_attributes: {},
});

const state = (overrides = {}) => ({
  suggestion_request_id: 'sr-42',
  status: 'no_reply',
  engine: 'agent',
  conversation_id: 42,
  stale: false,
  progress: null,
  result: {
    reason: 'Пациент только поблагодарил, вопросов нет.',
    reason_source: 'agent',
    agent: null,
    pending_actions: [],
  },
  ...overrides,
});

const draft = () =>
  state({
    status: 'draft',
    result: {
      message: 'Здравствуйте! Завтра в 10:00 есть окно.',
      agent: null,
      captain_trace: null,
      suggestion_meta: null,
      pending_actions: [],
      follow_up_context: { event_name: 'reply_suggestion' },
    },
  });

const buildStore = () =>
  createStore({
    getters: {
      getSelectedChat: () => mockChat.value,
      getMessageSignature: () => '',
      getCurrentUser: () => ({ id: 7, name: 'Менеджер' }),
      getLastEmailInSelectedChat: () => null,
      'globalConfig/get': () => ({}),
      getCurrentAccountId: () => 1,
      'accounts/isFeatureEnabledonAccount': () => () => false,
      'inboxes/getInbox': () => () => ({
        id: 1,
        channel_type: 'Channel::WebWidget',
      }),
      'inboxes/getConversationWhatsAppTemplates': () => () => [],
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
  });

const mountReplyBox = async () => {
  const wrapper = shallowMount(ReplyBox, {
    attachTo: document.body,
    global: {
      plugins: [buildStore()],
      mocks: { $t: key => key },
      directives: { 'on-clickaway': {} },
      // The notice is the unit under test: render it for real, stub the rest
      stubs: {
        CopilotSuggestionNotice: false,
        NextButton: NextButtonStub,
        Icon: true,
        // swap content at once instead of waiting for a CSS transition
        transition: PassThroughStub,
        Transition: PassThroughStub,
        CopilotReplyBottomPanel: CopilotReplyBottomPanelStub,
        CopilotEditorSection: CopilotEditorSectionStub,
        WootMessageEditor: MessageEditorStub,
        ReplyBottomPanel: ReplyBottomPanelStub,
        'woot-confirm-modal': true,
      },
    },
  });
  await flushPromises();
  return wrapper;
};

const find = selector => document.body.querySelector(selector);
const notice = () => find('[data-test="copilot-suggestion-notice"]');
const replyBox = () => find('.reply-box');
const panel = () => find('[data-test="copilot-panel"]');
const section = () => find('[data-test="copilot-section"]');
const editor = () => find('[data-test="message-editor"]');
const click = selector => {
  find(selector).click();
  return flushPromises();
};

describe('ReplyBox reply suggestion outcomes', () => {
  let wrapper;

  beforeEach(() => {
    vi.clearAllMocks();
    mockChat.value = chatOf(42);
    mockConversationId.value = 42;
    mockCancelReplySuggestion.mockResolvedValue({ ok: true });
    mockGetReplySuggestionStatus.mockResolvedValue({ suggestion: null });
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
  });

  it('renders a no_reply notice above the reply box, outside the editor', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state(),
    });

    wrapper = await mountReplyBox();

    expect(mockGetReplySuggestionStatus).toHaveBeenCalledWith({
      conversationId: 42,
    });
    expect(notice()).not.toBeNull();
    expect(notice().textContent).toContain(LABELS.NOTICE.NO_REPLY_TITLE);
    expect(notice().textContent).toContain(
      'Пациент только поблагодарил, вопросов нет.'
    );
    // a sibling that comes before the reply box, never inside it
    expect(replyBox()).not.toBeNull();
    expect(replyBox().contains(notice())).toBe(false);
    const inDocumentOrder = [
      ...document.body.querySelectorAll(
        '[data-test="copilot-suggestion-notice"], .reply-box'
      ),
    ];
    expect(inDocumentOrder).toEqual([notice(), replyBox()]);
  });

  it('keeps the normal editor and send panel and puts nothing into the message', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state({ status: 'human_needed' }),
    });

    wrapper = await mountReplyBox();

    expect(notice().getAttribute('data-kind')).toBe('human_needed');
    expect(editor()).not.toBeNull();
    expect(replyBox().contains(editor())).toBe(true);
    expect(section()).toBeNull();
    expect(panel()).toBeNull();
    expect(find('[data-test="reply-panel"]')).not.toBeNull();
    expect(wrapper.vm.message).toBe('');
  });

  it('does not offer to insert or send the notice text', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state(),
    });

    wrapper = await mountReplyBox();

    const buttons = [...notice().querySelectorAll('button')];
    // only the close button of a notice that cannot be retried
    expect(buttons).toHaveLength(1);
    expect(wrapper.vm.copilot.canAccept.value).toBe(false);
    wrapper.vm.onSubmitCopilotReply();
    expect(wrapper.vm.message).toBe('');
  });

  it('closes the notice and reports notice_dismissed', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state(),
    });
    wrapper = await mountReplyBox();

    await click('[data-test="copilot-notice-dismiss"]');

    expect(notice()).toBeNull();
    expect(TasksAPI.feedback).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: 42,
        suggestionRequestId: 'sr-42',
        outcome: 'notice_dismissed',
      })
    );
  });

  it('shows a failed run as a short status with «Повторить» that starts a new run', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state({
        status: 'failed',
        result: { reason_code: 'timeout' },
      }),
    });
    wrapper = await mountReplyBox();

    expect(notice().textContent).toContain(LABELS.NOTICE.FAILED_TITLE);
    expect(notice().textContent).not.toContain('timeout');
    mockStartReplySuggestion.mockResolvedValueOnce({
      state: state({ status: 'queued', suggestion_request_id: 'sr-new' }),
    });

    await click('[data-test="copilot-notice-retry"]');

    expect(mockStartReplySuggestion).toHaveBeenCalledTimes(1);
    expect(notice()).toBeNull();
    expect(wrapper.vm.copilot.suggestionPhase.value).toBe('queued');
    // the bottom panel switches to the generating state with a working cancel
    expect(panel()).not.toBeNull();
    expect(panel().getAttribute('data-generating')).toBe('true');
    expect(panel().getAttribute('data-can-cancel')).toBe('true');
    // and the section knows that the run waits in the queue
    expect(section().getAttribute('data-queued')).toBe('true');
  });

  it('cancels a running suggestion from the bottom panel', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state({ status: 'running', result: null }),
    });
    wrapper = await mountReplyBox();
    expect(panel().getAttribute('data-generating')).toBe('true');

    await click('[data-test="panel-cancel"]');

    expect(mockCancelReplySuggestion).toHaveBeenCalledWith({
      conversationId: 42,
      suggestionRequestId: 'sr-42',
    });
    expect(panel()).toBeNull();
    expect(editor()).not.toBeNull();
  });

  it('shows a restored draft in the copilot editor and no notice', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: { ...draft(), stale: true },
    });

    wrapper = await mountReplyBox();

    expect(notice()).toBeNull();
    expect(section()).not.toBeNull();
    expect(section().textContent).toContain(
      'Здравствуйте! Завтра в 10:00 есть окно.'
    );
    expect(section().getAttribute('data-stale')).toBe('true');
    expect(panel().getAttribute('data-generating')).toBe('false');
    expect(editor()).toBeNull();
  });

  it('inserts the draft into the message only on «Вставить»', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({ suggestion: draft() });
    wrapper = await mountReplyBox();
    expect(wrapper.vm.message).toBe('');

    await click('[data-test="panel-submit"]');

    expect(wrapper.vm.message).toBe('Здравствуйте! Завтра в 10:00 есть окно.');
    expect(TasksAPI.feedback).toHaveBeenCalledWith(
      expect.objectContaining({
        suggestionRequestId: 'sr-42',
        outcome: 'applied',
      })
    );
    expect(panel()).toBeNull();
  });

  it('drops the draft from «Отменить» without a second form', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({ suggestion: draft() });
    wrapper = await mountReplyBox();

    await click('[data-test="panel-reject"]');

    expect(TasksAPI.feedback).toHaveBeenCalledWith(
      expect.objectContaining({
        suggestionRequestId: 'sr-42',
        outcome: 'dismissed',
      })
    );
    expect(wrapper.vm.message).toBe('');
    expect(panel()).toBeNull();
    expect(section()).toBeNull();
    expect(editor()).not.toBeNull();
    expect(find('input[type="text"]')).toBeNull();
  });

  describe('Esc', () => {
    const pressEsc = (target = document.body, init = {}) => {
      target.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'Escape',
          code: 'Escape',
          bubbles: true,
          ...init,
        })
      );
      return flushPromises();
    };

    it.each([
      ['on the reply box', () => replyBox()],
      ['on the panel of the run', () => section()],
    ])(
      'cancels a suggestion that is being prepared when the focus is %s',
      async (_where, targetOf) => {
        mockGetReplySuggestionStatus.mockResolvedValueOnce({
          suggestion: state({ status: 'running', result: null }),
        });
        wrapper = await mountReplyBox();
        expect(panel()).not.toBeNull();

        await pressEsc(targetOf());

        expect(mockCancelReplySuggestion).toHaveBeenCalledTimes(1);
        expect(mockCancelReplySuggestion).toHaveBeenCalledWith({
          conversationId: 42,
          suggestionRequestId: 'sr-42',
        });
        expect(panel()).toBeNull();
        expect(editor()).not.toBeNull();
      }
    );

    it('keeps a running suggestion when Esc is pressed with the focus on the page', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: state({ status: 'running', result: null }),
      });
      wrapper = await mountReplyBox();

      // the manager clicked a chat image: the focus is on the body and the
      // same Esc closes the gallery
      await pressEsc(document.body);
      await pressEsc(document.documentElement);
      await pressEsc(document);

      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
      expect(panel()).not.toBeNull();
      expect(wrapper.vm.copilot.canCancel.value).toBe(true);
    });

    it('drops a ready draft like «Отменить» when the focus is in the reply box', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();

      await pressEsc(section());

      expect(TasksAPI.feedback).toHaveBeenCalledWith(
        expect.objectContaining({
          suggestionRequestId: 'sr-42',
          outcome: 'dismissed',
        })
      );
      expect(wrapper.vm.message).toBe('');
      expect(section()).toBeNull();
    });

    it('keeps a ready draft when Esc is pressed with the focus on the page', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();

      // the manager clicked a chat image: the focus is on the body and the
      // same Esc closes the gallery
      await pressEsc(document.body);
      await pressEsc(document.documentElement);
      await pressEsc(document);

      expect(section()).not.toBeNull();
      expect(panel()).not.toBeNull();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      expect(wrapper.vm.copilot.canAccept.value).toBe(true);
    });

    it('keeps a ready draft when another handler already took the Esc', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();
      const takeIt = event => event.preventDefault();
      document.addEventListener('keydown', takeIt, true);

      await pressEsc(section(), { cancelable: true });
      document.removeEventListener('keydown', takeIt, true);

      expect(section()).not.toBeNull();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();
    });

    it('keeps a running suggestion when another handler already took the Esc', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: state({ status: 'running', result: null }),
      });
      wrapper = await mountReplyBox();
      const takeIt = event => event.preventDefault();
      document.addEventListener('keydown', takeIt, true);

      await pressEsc(document.body, { cancelable: true });
      document.removeEventListener('keydown', takeIt, true);

      expect(panel()).not.toBeNull();
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
    });

    it('keeps a ready draft when Esc is pressed in a field of the reply box', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();
      // the CC field of an email reply: Esc only leaves the field
      const ccInput = document.createElement('input');
      replyBox().appendChild(ccInput);
      ccInput.focus();

      await pressEsc(ccInput);

      expect(section()).not.toBeNull();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      expect(document.activeElement).not.toBe(ccInput);
    });

    it('keeps a running suggestion when Esc is pressed in a field of the reply box', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: state({ status: 'running', result: null }),
      });
      wrapper = await mountReplyBox();
      // the CC field of an email reply, and a rich text field
      const ccInput = document.createElement('input');
      replyBox().appendChild(ccInput);
      const field = document.createElement('div');
      field.setAttribute('contenteditable', 'true');
      replyBox().appendChild(field);

      await pressEsc(ccInput);
      await pressEsc(field);

      expect(panel()).not.toBeNull();
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
    });

    it('keeps both states when Esc is pressed in a field inside the panel of the draft', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();
      const select = document.createElement('select');
      const textarea = document.createElement('textarea');
      section().append(select, textarea);

      await pressEsc(select);
      await pressEsc(textarea);

      expect(section()).not.toBeNull();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();
    });

    it('leaves the suggestion alone when the focus is in another field or dialog', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();
      const elsewhere = document.createElement('div');
      document.body.appendChild(elsewhere);

      await pressEsc(elsewhere);

      expect(section()).not.toBeNull();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      elsewhere.remove();
    });

    it('leaves a running suggestion alone when the focus is in a dialog', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: state({ status: 'running', result: null }),
      });
      wrapper = await mountReplyBox();
      const dialog = document.createElement('div');
      document.body.appendChild(dialog);

      await pressEsc(dialog);

      expect(panel()).not.toBeNull();
      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
      dialog.remove();
    });

    it('does nothing when no suggestion is active', async () => {
      wrapper = await mountReplyBox();

      await pressEsc();

      expect(mockCancelReplySuggestion).not.toHaveBeenCalled();
      expect(TasksAPI.feedback).not.toHaveBeenCalled();
      expect(editor()).not.toBeNull();
    });

    it('closes the emoji picker first and keeps the suggestion', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();
      wrapper.vm.showEmojiPicker = true;

      await pressEsc();

      expect(wrapper.vm.showEmojiPicker).toBe(false);
      expect(section()).not.toBeNull();
    });
  });

  describe('Enter', () => {
    const pressEnter = target => {
      target.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'Enter',
          code: 'Enter',
          bubbles: true,
          cancelable: true,
        })
      );
      return flushPromises();
    };
    let sendSpy;

    beforeEach(() => {
      sendSpy = vi
        .spyOn(ReplyBox.methods, 'onSendReply')
        .mockImplementation(() => {});
    });

    afterEach(() => {
      sendSpy.mockRestore();
    });

    it('sends the reply from the editor as before when no suggestion is shown', async () => {
      wrapper = await mountReplyBox();
      wrapper.vm.isFocused = true;

      await pressEnter(replyBox());

      expect(sendSpy).toHaveBeenCalledTimes(1);
    });

    it('does not send the hidden editor text while a draft is shown', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: draft(),
      });
      wrapper = await mountReplyBox();
      // the panel holds the focus, so the reply box counts as focused
      wrapper.vm.isFocused = true;

      await pressEnter(section());

      expect(sendSpy).not.toHaveBeenCalled();
      expect(section()).not.toBeNull();
      expect(wrapper.vm.copilot.canAccept.value).toBe(true);
    });

    it('does not send the hidden editor text while a suggestion is prepared', async () => {
      mockGetReplySuggestionStatus.mockResolvedValueOnce({
        suggestion: state({ status: 'running', result: null }),
      });
      wrapper = await mountReplyBox();
      wrapper.vm.isFocused = true;

      await pressEnter(section());

      expect(sendSpy).not.toHaveBeenCalled();
      expect(panel()).not.toBeNull();
    });
  });

  it('never carries a suggestion of one conversation into another', async () => {
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state(),
    });
    wrapper = await mountReplyBox();
    expect(notice()).not.toBeNull();

    // the manager opens conversation 99, which has nothing
    mockConversationId.value = 99;
    mockChat.value = chatOf(99);
    await flushPromises();

    expect(mockGetReplySuggestionStatus).toHaveBeenLastCalledWith({
      conversationId: 99,
    });
    expect(notice()).toBeNull();

    // a late result of conversation 42 does not show up in 99
    emitter.emit(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_RESULT, draft());
    emitter.emit(BUS_EVENTS.CAPTAIN_REPLY_SUGGESTION_RESULT, state());
    await flushPromises();
    expect(notice()).toBeNull();
    expect(section()).toBeNull();
    expect(panel()).toBeNull();
    expect(mockCancelReplySuggestion).not.toHaveBeenCalled();

    // coming back to 42 brings its notice back
    mockGetReplySuggestionStatus.mockResolvedValueOnce({
      suggestion: state(),
    });
    mockConversationId.value = 42;
    mockChat.value = chatOf(42);
    await flushPromises();

    expect(notice()).not.toBeNull();
    expect(notice().textContent).toContain('Пациент только поблагодарил');
  });
});
