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

const buildWrapper = ({ agents = [], routeQuery = {} } = {}) =>
  shallowMount(AddAgents, {
    global: {
      mocks: {
        $t: key => key,
        $route: {
          name: 'settings_inboxes_add_agents',
          params: { accountId: '530', inbox_id: '4690' },
          query: routeQuery,
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

  it('grants a messaging channel to every account employee without manual selection', async () => {
    const wrapper = buildWrapper({
      agents: [
        { id: 7, name: 'Agent One' },
        { id: 8, name: 'Agent Two' },
      ],
    });
    await flushPromises();

    expect(wrapper.vm.selectedAgentIds).toEqual([7, 8]);
    expect(wrapper.findComponent({ name: 'TagInput' }).exists()).toBe(false);

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
          configuration_version: 'sipuni-configuration-v1',
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
        expected_configuration_version: 'sipuni-configuration-v1',
        profiles: [
          {
            profile_kind: 'human_operator',
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
      { dryRun: false, remoteCommit: false }
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

  it('saves Virtual PBX Binotel employee SIP credentials without remote commit', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          configuration_version: 'binotel-configuration-v1',
          channel: { provider_kind: 'binotel' },
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
    wrapper.vm.virtualPbxProfiles[7].internalExtension = '901';
    wrapper.vm.virtualPbxProfiles[7].sipUsername = 'pq4dyw5f';
    wrapper.vm.virtualPbxProfiles[7].sipPassword = 'secret-901';

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      '4690',
      {
        expected_configuration_version: 'binotel-configuration-v1',
        profiles: [
          {
            profile_kind: 'human_operator',
            user_id: 7,
            internal_extension: '901',
            sip_username: 'pq4dyw5f',
            sip_password: 'secret-901',
            enabled: true,
          },
        ],
        metadata: {
          source: 'virtual_pbx_agents_step',
        },
      },
      { dryRun: false, remoteCommit: false }
    );
  });

  it('saves Asterisk analog employee SIP credentials for direct browser webphone', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          configuration_version: 'asterisk-configuration-v1',
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
    wrapper.vm.virtualPbxProfiles[7].sipUsername = '9098';
    wrapper.vm.virtualPbxProfiles[7].sipPassword = 'sip-secret';

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      '4690',
      {
        expected_configuration_version: 'asterisk-configuration-v1',
        profiles: [
          {
            profile_kind: 'human_operator',
            user_id: 7,
            internal_extension: '9098',
            sip_username: '9098',
            sip_password: 'sip-secret',
            enabled: true,
          },
        ],
        metadata: {
          source: 'virtual_pbx_agents_step',
        },
      },
      { dryRun: false, remoteCommit: false }
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
    );
  });

  it('uses the create-flow provider while status is unavailable and rejects an empty profile', async () => {
    const wrapper = buildWrapper({
      agents: [{ id: 7, name: 'Agent One' }],
      routeQuery: { provider: 'sipuni' },
    });
    await flushPromises();

    wrapper.vm.selectedAgentIds = [7];
    await wrapper.vm.$nextTick();

    expect(wrapper.vm.isVirtualPbxProfileAssignmentInbox).toBe(true);
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );

    await wrapper.vm.addAgents();
    await flushPromises();

    expect(inboxMembersUpdateMock).not.toHaveBeenCalled();
    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.REQUIRED'
    );
  });
});
