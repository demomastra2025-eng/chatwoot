import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import Index from './Index.vue';

let isUpdating = false;

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

function mountComponent() {
  return shallowMount(Index, {
    props: {
      conversations: [{ id: 1 }, { id: 2 }],
      selectedInboxes: [10],
      allConversationsSelected: false,
      showOpenAction: false,
      showResolvedAction: false,
      showSnoozedAction: false,
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
        CustomSnoozeModal: true,
        'woot-modal': true,
      },
      mocks: {
        $t: key => key,
      },
    },
  });
}

describe('ConversationBulkActions Index', () => {
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
    const wrapper = mountComponent();

    wrapper.findComponent(BulkLabelActionsStub).vm.$emit('assign', ['sales']);
    wrapper
      .findComponent(BulkUpdateActionsStub)
      .vm.$emit('update', 'resolved', null);
    wrapper
      .findComponent(BulkAgentActionsStub)
      .vm.$emit('select', { id: 1, name: 'Agent' });
    wrapper
      .findComponent(BulkTeamActionsStub)
      .vm.$emit('select', { id: 2, name: 'Team' });
    await wrapper.findAllComponents(NextButtonStub)[1].trigger('click');

    expect(wrapper.emitted('assignLabels')).toEqual([[['sales']]]);
    expect(wrapper.emitted('updateConversations')).toEqual([
      ['resolved', null],
    ]);
    expect(wrapper.emitted('assignAgent')).toEqual([
      [{ id: 1, name: 'Agent' }],
    ]);
    expect(wrapper.emitted('assignTeam')).toEqual([[{ id: 2, name: 'Team' }]]);
    expect(wrapper.emitted('markRead')).toEqual([[]]);
  });
});
