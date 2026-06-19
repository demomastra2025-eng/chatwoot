import { flushPromises, shallowMount } from '@vue/test-utils';

import AddAgents from './AddAgents.vue';

const inboxMembersUpdateMock = vi.hoisted(() => vi.fn());
const inboxMembersShowMock = vi.hoisted(() => vi.fn());
const routerReplaceMock = vi.hoisted(() => vi.fn());
const getVirtualPbxStatusMock = vi.hoisted(() => vi.fn());
const updateVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const alertMock = vi.hoisted(() => vi.fn());

vi.mock('../../../../api/inboxMembers', () => ({
  default: {
    show: inboxMembersShowMock,
    update: inboxMembersUpdateMock,
  },
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getVirtualPbxStatus: getVirtualPbxStatusMock,
    updateVirtualPbxChannel: updateVirtualPbxChannelMock,
  },
}));

vi.mock('../../../index', () => ({
  default: {
    replace: routerReplaceMock,
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

const buildWrapper = ({ agents = [] } = {}) =>
  shallowMount(AddAgents, {
    global: {
      mocks: {
        $t: key => key,
        $route: {
          name: 'settings_inboxes_add_agents',
          params: { accountId: '530', inbox_id: '4690' },
          query: {},
        },
        $store: {
          dispatch: vi.fn(),
          getters: {
            'agents/getAgents': agents,
          },
        },
      },
      stubs: {
        PageHeader: {
          template: '<section><slot name="content" /><slot /></section>',
        },
        NextButton: {
          template: '<button type="submit"><slot /></button>',
        },
        TagInput: true,
      },
    },
  });

describe('AddAgents', () => {
  beforeEach(() => {
    inboxMembersUpdateMock.mockReset();
    inboxMembersShowMock.mockReset();
    routerReplaceMock.mockReset();
    getVirtualPbxStatusMock.mockReset();
    updateVirtualPbxChannelMock.mockReset();
    alertMock.mockReset();
    inboxMembersUpdateMock.mockResolvedValue({});
    inboxMembersShowMock.mockResolvedValue({ data: { payload: [] } });
    getVirtualPbxStatusMock.mockRejectedValue(new Error('not virtual pbx'));
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
  });

  it('preserves accountId when moving to the finish step', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    wrapper.vm.selectedAgentIds = [7, 8];

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(inboxMembersUpdateMock).toHaveBeenCalledWith({
      inboxId: '4690',
      agentList: [7, 8],
    });
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inbox_finish',
      params: {
        accountId: '530',
        inbox_id: '4690',
      },
      query: {},
    });
  });

  it('saves Virtual PBX Sipuni employee SIP credentials before moving to the finish step', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          channel: { provider_kind: 'sipuni' },
          employees: [],
        },
      },
    });
    const wrapper = buildWrapper({
      agents: [{ id: 7, name: 'Agent One' }],
    });
    await flushPromises();

    wrapper.vm.selectedAgentIds = [7];
    await wrapper.vm.$nextTick();
    wrapper.vm.virtualPbxProfiles[7].internalExtension = '207';
    wrapper.vm.virtualPbxProfiles[7].sipUsername = '056124100014';
    wrapper.vm.virtualPbxProfiles[7].sipPassword = 'secret-207';

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(inboxMembersUpdateMock).toHaveBeenCalledWith({
      inboxId: '4690',
      agentList: [7],
    });
    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      '4690',
      {
        profiles: [
          {
            user_id: 7,
            internal_extension: '207',
            sip_username: '056124100014',
            sip_password: 'secret-207',
            enabled: true,
          },
        ],
        metadata: {
          source: 'virtual_pbx_agents_step',
        },
      },
      { dryRun: false, remoteCommit: true }
    );
    expect(alertMock).toHaveBeenCalledWith('INBOX_MGMT.AGENTS.SAVE_SUCCESS');
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inbox_finish',
      params: {
        accountId: '530',
        inbox_id: '4690',
      },
      query: {},
    });
  });

  it('saves Asterisk analog employee internal extensions without SIP credentials', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          channel: { provider_kind: 'asterisk_analog' },
          employees: [],
        },
      },
    });
    const wrapper = buildWrapper({
      agents: [{ id: 7, name: 'Agent One' }],
    });
    await flushPromises();

    wrapper.vm.selectedAgentIds = [7];
    await wrapper.vm.$nextTick();
    wrapper.vm.virtualPbxProfiles[7].internalExtension = '9098';
    wrapper.vm.virtualPbxProfiles[7].sipUsername = 'must-not-send';
    wrapper.vm.virtualPbxProfiles[7].sipPassword = 'must-not-send';

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      '4690',
      {
        profiles: [
          {
            user_id: 7,
            internal_extension: '9098',
            enabled: true,
          },
        ],
        metadata: {
          source: 'virtual_pbx_agents_step',
        },
      },
      { dryRun: false, remoteCommit: true }
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
    );
  });
});
