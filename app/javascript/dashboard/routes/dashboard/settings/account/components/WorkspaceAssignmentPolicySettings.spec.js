import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import WorkspaceAssignmentPolicySettings from './WorkspaceAssignmentPolicySettings.vue';

const { getPoliciesMock, updateAccountMock, alertMock } = vi.hoisted(() => ({
  getPoliciesMock: vi.fn(),
  updateAccountMock: vi.fn(),
  alertMock: vi.fn(),
}));

const currentAccount = ref({
  id: 1,
  settings: {},
});
const accountId = ref(1);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount,
    accountId,
    updateAccount: updateAccountMock,
  }),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));

vi.mock('dashboard/api/assignmentPolicies', () => ({
  default: { get: getPoliciesMock },
}));

const mountComponent = () =>
  shallowMount(WorkspaceAssignmentPolicySettings, {
    global: {
      stubs: {
        SectionLayout: { template: '<section><slot /></section>' },
        Select: {
          props: ['modelValue', 'disabled'],
          emits: ['update:modelValue'],
          template:
            '<select data-test="workspace-assignment-policy-select" :value="modelValue" :disabled="disabled" @change="$emit(\'update:modelValue\', $event.target.value)"><slot /></select>',
        },
        Button: {
          props: ['disabled', 'label', 'isLoading'],
          emits: ['click'],
          template:
            '<button data-test="workspace-assignment-policy-save" :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
        },
      },
    },
  });

describe('WorkspaceAssignmentPolicySettings', () => {
  beforeEach(() => {
    currentAccount.value = { id: 1, settings: {} };
    accountId.value = 1;
    getPoliciesMock.mockReset();
    getPoliciesMock.mockResolvedValue({
      data: [
        { id: 20, name: 'All conversations', enabled: true },
        { id: 21, name: 'Disabled policy', enabled: false },
      ],
    });
    updateAccountMock.mockReset();
    updateAccountMock.mockImplementation(async payload => {
      currentAccount.value = {
        ...currentAccount.value,
        settings: { ...currentAccount.value.settings, ...payload },
      };
    });
    alertMock.mockReset();
  });

  it('keeps the existing channel settings until an administrator selects a workspace policy', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_LEGACY_NOTICE'
    );
    expect(wrapper.find('option[value="21"]').exists()).toBe(false);
    expect(wrapper.text()).toContain(
      'GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_PHONE_LINE_NOTE'
    );
  });

  it('saves a selected policy as a workspace setting', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .get('[data-test="workspace-assignment-policy-select"]')
      .setValue('20');
    await wrapper.get('[data-test="workspace-assignment-policy-save"]').trigger('click');

    expect(updateAccountMock).toHaveBeenCalledWith(
      { conversation_assignment_policy_id: 20 },
      { silent: true }
    );
    expect(alertMock).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UPDATE_SUCCESS'
    );
  });

  it('lets an administrator clear a stale selected policy to return to legacy settings', async () => {
    currentAccount.value.settings.conversation_assignment_policy_id = 21;
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'GENERAL_SETTINGS.CONVERSATIONS.ASSIGNMENT_POLICY_UNAVAILABLE'
    );
    await wrapper
      .get('[data-test="workspace-assignment-policy-select"]')
      .setValue('');
    await wrapper.get('[data-test="workspace-assignment-policy-save"]').trigger('click');

    expect(updateAccountMock).toHaveBeenCalledWith(
      { conversation_assignment_policy_id: null },
      { silent: true }
    );
  });
});
