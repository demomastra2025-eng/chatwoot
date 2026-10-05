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

const buildWrapper = () =>
  shallowMount(CollaboratorsPage, {
    props: { inbox },
    global: {
      mocks: { $t: key => key },
      stubs: { 'woot-input': true },
    },
  });

describe('CollaboratorsPage voice inbox', () => {
  beforeEach(() => {
    mocks.alert.mockReset();
    mocks.dispatch.mockReset();
    mocks.getVirtualPbxStatus.mockReset();
    mocks.updateVirtualPbxChannel.mockReset();
    mocks.dispatch.mockResolvedValue({ data: { payload: [] } });
  });

  it('has no setting that shows the calls of other operators', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    expect(wrapper.find('[data-test="handled-call-visibility"]').exists()).toBe(
      false
    );
    expect(wrapper.html()).not.toContain('HANDLED_CALL_VISIBILITY');
  });

  it('never loads or changes the Virtual PBX channel from the employees page', async () => {
    buildWrapper();
    await flushPromises();

    expect(mocks.getVirtualPbxStatus).not.toHaveBeenCalled();
    expect(mocks.updateVirtualPbxChannel).not.toHaveBeenCalled();
  });
});
