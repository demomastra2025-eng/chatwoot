import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentAssignmentPolicyForm from './AgentAssignmentPolicyForm.vue';

const { dispatchMock } = vi.hoisted(() => ({
  dispatchMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '74' } }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: dispatchMock }),
  useMapGetter: key => {
    if (key === 'accounts/isFeatureEnabledonAccount') {
      return { value: () => true };
    }
    return { value: [] };
  },
}));

const agents = [
  { id: 6, name: 'Асет', role: 'administrator' },
  { id: 103, name: 'Светлана Ротару', role: 'agent' },
];

const mountForm = (props = {}) =>
  mount(AgentAssignmentPolicyForm, {
    props: {
      mode: 'EDIT',
      agentList: agents,
      initialData: {
        name: 'Политика по умолчанию',
        description: 'Автоматическое распределение',
        enabled: true,
        assignmentOrder: 'round_robin',
        conversationPriority: 'earliest_created',
        fairDistributionLimit: 100,
        fairDistributionWindow: 3600,
        assignmentDelayMinutes: 0,
        maxOpenConversations: null,
        assignOnlineOnly: true,
        assignPendingConversations: false,
        exclusionRules: {
          excludedLabels: [],
          excludeOlderThanMinutes: null,
          excludedUserIds: [],
        },
        monthlyNewClientQuota: null,
        stickyOwnerEnabled: false,
        stickyOwnerDurationDays: 30,
      },
      ...props,
    },
    global: {
      stubs: {
        BaseInfo: {
          emits: ['validationChange'],
          mounted() {
            this.$emit('validationChange', { isValid: true });
          },
          template: '<div data-test="base-info-stub" />',
        },
        WithLabel: { template: '<div><slot /></div>' },
        RadioCard: { template: '<div />' },
        FairDistribution: { template: '<div />' },
        ExclusionRules: { template: '<div />' },
        LoadControls: { template: '<div />' },
        Button: {
          props: ['label', 'disabled', 'type'],
          template:
            '<button :type="type" :disabled="disabled">{{ label }}</button>',
        },
      },
    },
  });

describe('AgentAssignmentPolicyForm', () => {
  beforeEach(() => {
    dispatchMock.mockClear();
  });

  it('renders workspace employees with checkboxes checked by default and lets admin exclude specific employees', async () => {
    const wrapper = mountForm();

    const assetCheckbox = wrapper.get('[data-test="assignment-policy-agent-6"]');
    const svetlanaCheckbox = wrapper.get(
      '[data-test="assignment-policy-agent-103"]'
    );

    expect(assetCheckbox.element.checked).toBe(true);
    expect(svetlanaCheckbox.element.checked).toBe(true);

    // Uncheck Asset (id = 6) so he does not receive auto-assigned conversations
    await assetCheckbox.trigger('change');
    expect(assetCheckbox.element.checked).toBe(false);

    await wrapper.get('form').trigger('submit.prevent');

    expect(wrapper.emitted('submit')).toHaveLength(1);
    expect(wrapper.emitted('submit')[0][0].exclusionRules.excludedUserIds).toEqual([
      6,
    ]);
  });

  it('supports Clear all and Select all actions for employees', async () => {
    const wrapper = mountForm();

    await wrapper
      .get('[data-test="assignment-policy-clear-all-agents"]')
      .trigger('click');

    expect(
      wrapper.get('[data-test="assignment-policy-agent-6"]').element.checked
    ).toBe(false);
    expect(
      wrapper.get('[data-test="assignment-policy-agent-103"]').element.checked
    ).toBe(false);

    await wrapper.get('form').trigger('submit.prevent');
    expect(
      wrapper.emitted('submit')[0][0].exclusionRules.excludedUserIds
    ).toEqual([6, 103]);

    await wrapper
      .get('[data-test="assignment-policy-select-all-agents"]')
      .trigger('click');

    await wrapper.get('form').trigger('submit.prevent');
    expect(
      wrapper.emitted('submit')[1][0].exclusionRules.excludedUserIds
    ).toEqual([]);
  });
});
