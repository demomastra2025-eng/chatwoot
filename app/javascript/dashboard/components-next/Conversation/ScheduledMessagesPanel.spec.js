import { ref } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import ScheduledMessagesPanel from './ScheduledMessagesPanel.vue';
import {
  clearScheduledMessageDraft,
  setScheduledMessageDraft,
} from 'dashboard/composables/useScheduledMessageDraft';

const mocks = vi.hoisted(() => ({
  get: vi.fn(),
  cancel: vi.fn(),
  alert: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
    locale: ref('en'),
  }),
}));

vi.mock('dashboard/api/touches', () => ({
  default: {
    get: mocks.get,
    cancel: mocks.cancel,
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: ref({ id: 1, reporting_timezone: 'UTC' }),
  }),
}));

const ButtonStub = {
  name: 'Button',
  props: ['label'],
  emits: ['click'],
  template: '<button @click="$emit(\'click\')">{{ label }}</button>',
};

let activeWrapper;
const mountComponent = () => {
  activeWrapper = shallowMount(ScheduledMessagesPanel, {
    props: {
      conversationId: 12,
      remindableId: 12,
      remindableType: 'Conversation',
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Button: ButtonStub,
        Spinner: true,
        TouchEditorDrawer: {
          name: 'TouchEditorDrawer',
          props: ['modelValue', 'touch', 'initialBody', 'initialAttachments'],
          template: '<div />',
        },
      },
    },
  });
  return activeWrapper;
};

describe('ScheduledMessagesPanel', () => {
  beforeEach(() => {
    mocks.get.mockReset();
    mocks.cancel.mockReset();
    mocks.alert.mockReset();
    clearScheduledMessageDraft();
  });

  afterEach(() => {
    activeWrapper?.unmount();
    activeWrapper = null;
  });

  it('shows only manual pending scheduled messages', async () => {
    mocks.get.mockResolvedValue({
      data: {
        payload: [
          { id: 1, status: 'pending', body: 'Manual message', metadata: {} },
          {
            id: 2,
            status: 'pending',
            body: 'Automation message',
            metadata: { automation_rule_id: 8 },
          },
          { id: 3, status: 'delivered', body: 'Delivered', metadata: {} },
        ],
      },
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Manual message');
    expect(wrapper.text()).not.toContain('Automation message');
    expect(wrapper.text()).not.toContain('Delivered');
    expect(mocks.get).toHaveBeenCalledWith({
      conversation_id: 12,
      remindable_id: 12,
      remindable_type: 'Conversation',
    });
  });

  it('cancels a manual scheduled message and refreshes the list', async () => {
    mocks.get
      .mockResolvedValueOnce({
        data: {
          payload: [
            { id: 1, status: 'pending', body: 'Manual message', metadata: {} },
          ],
        },
      })
      .mockResolvedValueOnce({ data: { payload: [] } });
    mocks.cancel.mockResolvedValue({});

    const wrapper = mountComponent();
    await flushPromises();
    await wrapper
      .findAll('button')
      .find(button =>
        button.text().includes('CONVERSATION.SCHEDULED_MESSAGES.CANCEL')
      )
      .trigger('click');
    await flushPromises();

    expect(mocks.cancel).toHaveBeenCalledWith(1, {
      reason: 'cancelled_from_conversation',
    });
    expect(mocks.get).toHaveBeenCalledTimes(2);
  });

  it('ignores a stale response after the conversation changes', async () => {
    let resolveFirstRequest;
    mocks.get
      .mockReturnValueOnce(
        new Promise(resolve => {
          resolveFirstRequest = resolve;
        })
      )
      .mockResolvedValueOnce({
        data: {
          payload: [
            { id: 2, status: 'pending', body: 'Current message', metadata: {} },
          ],
        },
      });

    const wrapper = mountComponent();
    await wrapper.setProps({ conversationId: 24, remindableId: 24 });
    await flushPromises();
    resolveFirstRequest({
      data: {
        payload: [
          { id: 1, status: 'pending', body: 'Stale message', metadata: {} },
        ],
      },
    });
    await flushPromises();

    expect(wrapper.text()).toContain('Current message');
    expect(wrapper.text()).not.toContain('Stale message');
  });

  it('opens the editor with the draft body and uploaded attachments', async () => {
    mocks.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mountComponent();
    await flushPromises();

    setScheduledMessageDraft({
      accountId: 1,
      body: 'Draft from reply editor',
      attachments: [{ signed_id: 'blob-1', filename: 'quote.pdf' }],
      conversationId: 12,
      remindableId: 12,
      remindableType: 'Conversation',
    });
    await flushPromises();
    const editor = wrapper.findComponent({ name: 'TouchEditorDrawer' });

    expect(editor.props('modelValue')).toBe(true);
    expect(editor.props('initialBody')).toBe('Draft from reply editor');
    expect(editor.props('initialAttachments')).toEqual([
      { signed_id: 'blob-1', filename: 'quote.pdf' },
    ]);
  });
});
