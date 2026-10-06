import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { emitter } from 'shared/helpers/mitt';
import { CMD_BULK_ACTION_SNOOZE_CONVERSATION } from 'dashboard/helper/commandbar/events';

import Index from './Index.vue';

let isUpdating = false;
let emitterHandlers = {};

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: vi.fn(key => {
    if (key === 'bulkActions/getCurrentBulkActionRun') return ref(null);
    if (key === 'bulkActions/getUIFlags') return ref({ isUpdating });
    return ref(null);
  }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values = {}) =>
      `${key}${Object.keys(values).length ? JSON.stringify(values) : ''}`,
  }),
}));

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    on: vi.fn(),
    off: vi.fn(),
  },
}));

vi.mock('dashboard/helper/snoozeHelpers', () => ({
  findSnoozeTime: vi.fn(() => 123456),
}));

vi.mock('date-fns', () => ({
  getUnixTime: vi.fn(() => 123456),
}));

const BulkAgentActionsStub = {
  name: 'BulkAgentActions',
  props: {
    disabled: {
      type: Boolean,
      default: false,
    },
    selectedInboxes: {
      type: Array,
      default: () => [],
    },
    conversationCount: {
      type: Number,
      default: 0,
    },
  },
  emits: ['select'],
  template: '<div />',
};

const BulkLabelActionsStub = {
  name: 'BulkLabelActions',
  props: {
    disabled: {
      type: Boolean,
      default: false,
    },
  },
  emits: ['assign'],
  template: '<div />',
};

const BulkTeamActionsStub = {
  name: 'BulkTeamActions',
  props: {
    disabled: {
      type: Boolean,
      default: false,
    },
    conversationCount: {
      type: Number,
      default: 0,
    },
  },
  emits: ['select'],
  template: '<div />',
};

const BulkUpdateActionsStub = {
  name: 'BulkUpdateActions',
  props: {
    disabled: {
      type: Boolean,
      default: false,
    },
    showResolve: {
      type: Boolean,
      default: true,
    },
    showReopen: {
      type: Boolean,
      default: true,
    },
    showSnooze: {
      type: Boolean,
      default: true,
    },
  },
  emits: ['update'],
  template: '<div />',
};

const CheckboxStub = {
  name: 'Checkbox',
  props: {
    disabled: {
      type: Boolean,
      default: false,
    },
    indeterminate: {
      type: Boolean,
      default: false,
    },
    modelValue: {
      type: Boolean,
      default: false,
    },
  },
  emits: ['update:modelValue'],
  template: '<input type="checkbox" :disabled="disabled" />',
};

const NextButtonStub = {
  name: 'NextButton',
  props: {
    disabled: {
      type: Boolean,
      default: false,
    },
  },
  emits: ['click'],
  template: '<button :disabled="disabled" @click="$emit(\'click\')" />',
};

const statusReasonCancelled = Symbol('cancelled');
const ConversationStatusReasonDialogStub = {
  name: 'ConversationStatusReasonDialog',
  data: () => ({ CANCELLED: statusReasonCancelled, pendingResolver: null }),
  methods: {
    open: vi.fn(async () => null),
    cancel: vi.fn(),
  },
  template: '<div />',
};

const DialogStub = {
  name: 'Dialog',
  props: ['type', 'title', 'description', 'confirmButtonLabel'],
  emits: ['confirm', 'close'],
  methods: {
    open: vi.fn(),
    close: vi.fn(),
  },
  template: '<div />',
};

function mountComponent(props = {}) {
  return shallowMount(Index, {
    props: {
      selectedCount: 2,
      selectionVersion: 1,
      selectionContextKey: 'account-1:open',
      selectedInboxes: [10],
      allConversationsSelected: false,
      showOpenAction: false,
      showResolvedAction: false,
      showSnoozedAction: false,
      ...props,
    },
    global: {
      stubs: {
        Transition: {
          template: '<div><slot /></div>',
        },
        Checkbox: CheckboxStub,
        NextButton: NextButtonStub,
        BulkAgentActions: BulkAgentActionsStub,
        BulkLabelActions: BulkLabelActionsStub,
        BulkTeamActions: BulkTeamActionsStub,
        BulkUpdateActions: BulkUpdateActionsStub,
        ConversationStatusReasonDialog: ConversationStatusReasonDialogStub,
        Dialog: DialogStub,
        CustomSnoozeModal: true,
        'woot-modal': true,
      },
      mocks: {
        $t: (key, values = {}) =>
          `${key}${Object.keys(values).length ? JSON.stringify(values) : ''}`,
      },
    },
  });
}

describe('ConversationBulkActions Index', () => {
  beforeEach(() => {
    emitterHandlers = {};
    emitter.on.mockImplementation((event, handler) => {
      emitterHandlers[event] = handler;
    });
    ConversationStatusReasonDialogStub.methods.open.mockReset();
    ConversationStatusReasonDialogStub.methods.open.mockResolvedValue(null);
    ConversationStatusReasonDialogStub.methods.cancel.mockReset();
  });

  it('passes disabled state to every bulk action control while a run is updating', () => {
    isUpdating = true;

    const wrapper = mountComponent();

    expect(wrapper.findComponent(BulkLabelActionsStub).props('disabled')).toBe(
      true
    );
    expect(wrapper.findComponent(BulkUpdateActionsStub).props('disabled')).toBe(
      true
    );
    expect(wrapper.findComponent(BulkAgentActionsStub).props('disabled')).toBe(
      true
    );
    expect(wrapper.findComponent(BulkTeamActionsStub).props('disabled')).toBe(
      true
    );
    expect(wrapper.findComponent(CheckboxStub).props('disabled')).toBe(true);
    expect(wrapper.findAllComponents(NextButtonStub)[0].props('disabled')).toBe(
      true
    );
    expect(
      wrapper
        .findAllComponents(NextButtonStub)
        .some(button => button.props('disabled'))
    ).toBe(true);
  });

  it('emits bulk actions to the parent owner instead of invoking a local composable instance', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 1 });

    wrapper.findComponent(BulkLabelActionsStub).vm.$emit('assign', ['sales']);
    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'open', null);
    wrapper
      .findComponent(BulkAgentActionsStub)
      .vm.$emit('select', { id: 1, name: 'Agent' });
    wrapper
      .findComponent(BulkTeamActionsStub)
      .vm.$emit('select', { id: 2, name: 'Team' });
    await wrapper.findAllComponents(NextButtonStub)[1].trigger('click');
    await flushPromises();

    expect(wrapper.emitted('assignLabels')).toEqual([[['sales']]]);
    expect(wrapper.emitted('updateConversations')).toEqual([
      ['open', null, null],
    ]);
    expect(wrapper.emitted('assignAgent')).toEqual([
      [{ id: 1, name: 'Agent' }],
    ]);
    expect(wrapper.emitted('assignTeam')).toEqual([[{ id: 2, name: 'Team' }]]);
    expect(wrapper.emitted('markRead')).toEqual([[]]);
  });

  it('renders the panel in the list flow at the top instead of floating over the bottom', () => {
    isUpdating = false;
    const wrapper = mountComponent();
    const panel = wrapper.find(
      '[data-test-id="conversation-bulk-actions-panel"]'
    );

    expect(panel.exists()).toBe(true);
    expect(panel.classes()).toEqual(
      expect.arrayContaining(['shrink-0', 'origin-top', 'w-full'])
    );
    expect(panel.classes()).not.toContain('absolute');
    expect(panel.classes()).not.toContain('bottom-20');
  });

  it('keeps the status reason dialog for bulk status changes', () => {
    isUpdating = false;
    const wrapper = mountComponent();

    expect(
      wrapper.findComponent(ConversationStatusReasonDialogStub).exists()
    ).toBe(true);
  });

  it('routes the command bar snooze event through the bulk update callback', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 3 });

    emitterHandlers[CMD_BULK_ACTION_SNOOZE_CONVERSATION](12345);
    await flushPromises();

    expect(wrapper.emitted('updateConversations')).toEqual([
      ['snoozed', 12345, null],
    ]);
  });

  it('shows the exact all-matching count before confirming a multi-close', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 37 });

    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    await flushPromises();

    const confirmation = wrapper.findComponent(DialogStub);
    expect(confirmation.props('description')).toBe(
      'BULK_ACTION.CLOSE_CONFIRMATION.DESCRIPTION{"count":37}'
    );
  });

  it('explains the cap alongside the exact close count for a search snapshot', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 2, isSearchCapped: true });

    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    await flushPromises();

    expect(wrapper.findComponent(DialogStub).props('description')).toBe(
      'BULK_ACTION.CLOSE_CONFIRMATION.DESCRIPTION{"count":2} BULK_ACTION.CLOSE_CONFIRMATION.SEARCH_CAPPED{"count":2}'
    );
    expect(wrapper.emitted('updateConversations')).toBeUndefined();
  });

  it('requires confirmation when closing one selected conversation', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 1 });

    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    await flushPromises();

    expect(wrapper.findComponent(DialogStub).props('description')).toBe(
      'BULK_ACTION.CLOSE_CONFIRMATION.DESCRIPTION{"count":1}'
    );
    expect(wrapper.emitted('updateConversations')).toBeUndefined();
  });

  it('does not submit a close after the user cancels the count confirmation', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 37 });

    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    await flushPromises();
    wrapper.findComponent(DialogStub).vm.$emit('close');
    await flushPromises();

    expect(
      ConversationStatusReasonDialogStub.methods.open
    ).not.toHaveBeenCalled();
    expect(wrapper.emitted('updateConversations')).toBeUndefined();
  });

  it('cancels a count confirmation when selection context changes while it is open', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 37 });
    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    await flushPromises();

    await wrapper.setProps({
      selectionVersion: 2,
      selectionContextKey: 'account-1:pending',
    });
    await flushPromises();

    expect(
      ConversationStatusReasonDialogStub.methods.open
    ).not.toHaveBeenCalled();
    expect(wrapper.emitted('updateConversations')).toBeUndefined();
  });

  it('cancels a status reason request when its selection context changes', async () => {
    isUpdating = false;
    const wrapper = mountComponent({ selectedCount: 37 });
    const confirmation = wrapper.findComponent(DialogStub);
    let resolveReason;
    ConversationStatusReasonDialogStub.methods.open.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveReason = resolve;
        })
    );
    ConversationStatusReasonDialogStub.methods.cancel.mockImplementationOnce(
      () => resolveReason(statusReasonCancelled)
    );

    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    await flushPromises();
    confirmation.vm.$emit('confirm');
    await flushPromises();
    expect(
      ConversationStatusReasonDialogStub.methods.open
    ).toHaveBeenCalledWith({ status: 'resolved' });

    await wrapper.setProps({
      selectionVersion: 2,
      selectionContextKey: 'account-1:pending',
    });
    await flushPromises();

    expect(
      ConversationStatusReasonDialogStub.methods.cancel
    ).toHaveBeenCalled();
    expect(wrapper.emitted('updateConversations')).toBeUndefined();
  });
});
