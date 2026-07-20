import { flushPromises, shallowMount } from '@vue/test-utils';

import CollaboratorsPage from './CollaboratorsPage.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  dispatch: vi.fn(),
  getVirtualPbxStatus: vi.fn(),
  updateVirtualPbxChannel: vi.fn(),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({ isEnterprise: false }),
}));

vi.mock('vuex', () => ({
  useStore: () => ({
    dispatch: mocks.dispatch,
    getters: {
      'agents/getAgents': [],
      'accounts/isFeatureEnabledonAccount': () => false,
    },
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: 43 } }),
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/assignmentPolicies', () => ({
  default: {
    getInboxPolicy: vi.fn(),
    get: vi.fn(),
  },
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getVirtualPbxStatus: mocks.getVirtualPbxStatus,
    updateVirtualPbxChannel: mocks.updateVirtualPbxChannel,
  },
}));

const inbox = {
  id: 194,
  channel_type: 'Channel::Voice',
  provider: 'sipuni',
  enable_auto_assignment: false,
  auto_assignment_config: {},
};

const buildWrapper = ({ inbox: inboxProp = inbox } = {}) =>
  shallowMount(CollaboratorsPage, {
    props: { inbox: inboxProp },
    global: {
      mocks: { $t: key => key },
      stubs: { 'woot-input': true },
    },
  });

describe('CollaboratorsPage call visibility', () => {
  beforeEach(() => {
    mocks.alert.mockReset();
    mocks.dispatch.mockReset();
    mocks.getVirtualPbxStatus.mockReset();
    mocks.updateVirtualPbxChannel.mockReset();
    mocks.dispatch.mockResolvedValue({ data: { payload: [] } });
    mocks.getVirtualPbxStatus.mockResolvedValue({
      payload: {
        ui_config: {
          configuration_version: 'config-version-1',
          status: { read_only: false },
          routing: { show_calls_handled_by_other_operators: true },
        },
      },
    });
    mocks.updateVirtualPbxChannel.mockResolvedValue({
      payload: {
        errors: [],
        ui_config: { configuration_version: 'config-version-2' },
      },
    });
  });

  it('loads and updates handled-call visibility from the employees page', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    expect(mocks.getVirtualPbxStatus).toHaveBeenCalledWith(194);
    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    expect(toggle.exists()).toBe(true);
    expect(toggle.props('modelValue')).toBe(true);

    toggle.vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(mocks.updateVirtualPbxChannel).toHaveBeenCalledWith(
      194,
      {
        expected_configuration_version: 'config-version-1',
        routing: {
          show_calls_handled_by_other_operators: false,
        },
      },
      { dryRun: false, remoteCommit: false }
    );
  });

  it('disables handled-call visibility when Virtual PBX settings are read-only', async () => {
    mocks.getVirtualPbxStatus.mockResolvedValue({
      payload: {
        ui_config: {
          status: { read_only: true },
          routing: { show_calls_handled_by_other_operators: false },
        },
      },
    });

    const wrapper = buildWrapper();
    await flushPromises();

    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    expect(toggle.props('disabled')).toBe(true);
  });

  it('fails closed when handled-call visibility cannot be loaded', async () => {
    mocks.getVirtualPbxStatus.mockRejectedValue(new Error('status failed'));

    const wrapper = buildWrapper();
    await flushPromises();

    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    expect(toggle.props('disabled')).toBe(true);
    expect(mocks.alert).toHaveBeenCalledWith(
      'INBOX_MGMT.EDIT.API.ERROR_MESSAGE'
    );
  });

  it('restores the persisted visibility when the update fails', async () => {
    mocks.updateVirtualPbxChannel.mockRejectedValue(new Error('update failed'));
    const wrapper = buildWrapper();
    await flushPromises();

    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    toggle.vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(toggle.props('modelValue')).toBe(true);
    expect(mocks.alert).toHaveBeenCalledWith(
      'INBOX_MGMT.EDIT.API.ERROR_MESSAGE'
    );
  });

  it('shows the actionable active-call error returned by the backend', async () => {
    mocks.updateVirtualPbxChannel.mockResolvedValue({
      payload: {
        errors: [
          {
            code: 'active_calls_present',
            message: 'Channel has active calls and cannot be updated',
          },
        ],
      },
    });
    const wrapper = buildWrapper();
    await flushPromises();

    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    toggle.vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(toggle.props('modelValue')).toBe(true);
    expect(mocks.alert).toHaveBeenCalledWith(
      'INBOX_MGMT.EDIT.VIRTUAL_PBX.HANDLED_CALL_VISIBILITY.ACTIVE_CALL_ERROR'
    );
  });

  it('ignores a stale status response after switching inboxes', async () => {
    let resolveFirstRequest;
    mocks.getVirtualPbxStatus
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveFirstRequest = resolve;
          })
      )
      .mockResolvedValueOnce({
        payload: {
          ui_config: {
            status: { read_only: false },
            routing: { show_calls_handled_by_other_operators: false },
          },
        },
      });
    const wrapper = buildWrapper();
    await flushPromises();

    await wrapper.setProps({ inbox: { ...inbox, id: 195 } });
    await flushPromises();
    resolveFirstRequest({
      payload: {
        ui_config: {
          configuration_version: 'config-version-1',
          status: { read_only: false },
          routing: { show_calls_handled_by_other_operators: true },
        },
      },
    });
    await flushPromises();

    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    expect(mocks.getVirtualPbxStatus).toHaveBeenLastCalledWith(195);
    expect(toggle.props('modelValue')).toBe(false);
  });

  it('ignores a stale update response after switching away from and back to an inbox', async () => {
    let resolveUpdate;
    mocks.updateVirtualPbxChannel.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveUpdate = resolve;
        })
    );
    const wrapper = buildWrapper();
    await flushPromises();

    wrapper
      .findComponent('[data-test="handled-call-visibility"]')
      .vm.$emit('update:modelValue', false);
    await flushPromises();
    await wrapper.setProps({ inbox: { ...inbox, id: 195 } });
    await flushPromises();
    await wrapper.setProps({ inbox: { ...inbox, id: 194 } });
    await flushPromises();

    resolveUpdate({ payload: { errors: [] } });
    await flushPromises();

    const toggle = wrapper.findComponent(
      '[data-test="handled-call-visibility"]'
    );
    expect(toggle.props('modelValue')).toBe(true);
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'
    );
  });
});
