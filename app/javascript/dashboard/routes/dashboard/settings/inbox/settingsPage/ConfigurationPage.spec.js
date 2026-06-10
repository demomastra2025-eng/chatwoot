import { flushPromises, shallowMount } from '@vue/test-utils';

import ConfigurationPage from './ConfigurationPage.vue';

const alertMock = vi.hoisted(() => vi.fn());
const getVirtualPbxStatusMock = vi.hoisted(() => vi.fn());
const updateVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const deleteVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const routerPushMock = vi.hoisted(() => vi.fn());

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getVirtualPbxStatus: getVirtualPbxStatusMock,
    updateVirtualPbxChannel: updateVirtualPbxChannelMock,
    deleteVirtualPbxChannel: deleteVirtualPbxChannelMock,
  },
}));

const baseInbox = {
  id: 42,
  name: 'Virtual PBX',
  channel_type: 'Channel::Voice',
  provider: 'fonoster',
  phone_number: '+77271234567',
  provider_config: {},
};

const statusPayload = {
  payload: {
    config: {
      name: 'Virtual PBX',
      provider_kind: 'sipuni',
      phone_numbers: {
        display_phone_number: '+77271234567',
        provider_account_number: '3100000',
        ingress_number: '3100000',
      },
      resources: {
        provider_connection: {
          host: 'sip.provider.local',
          port: 5060,
          transport: 'udp',
          username: 'trunk-user',
        },
      },
      routing: {
        mode: 'operator',
        operator_agent_aor: 'sip:100@sip.provider.local',
      },
      ownership: {
        read_only: false,
      },
    },
    warnings: [],
    errors: [],
  },
};

const buildWrapper = () =>
  shallowMount(ConfigurationPage, {
    props: {
      inbox: baseInbox,
    },
    global: {
      mocks: {
        $t: key => key,
        $store: {
          dispatch: vi.fn(),
        },
        $route: {
          params: { accountId: 530 },
        },
        $router: {
          push: routerPushMock,
        },
      },
      stubs: {
        SettingsFieldSection: {
          template: '<section><slot /></section>',
        },
        SettingsToggleSection: true,
        SettingsAccordion: true,
        ImapSettings: true,
        SmtpSettings: true,
        WhatsappReauthorize: true,
        FonosterReadiness: true,
        FonosterRoutingForm: true,
        TextArea: true,
        'woot-code': true,
        'woot-input': true,
        NextButton: {
          template: '<button><slot /></button>',
        },
      },
    },
  });

describe('ConfigurationPage Virtual PBX management', () => {
  beforeEach(() => {
    alertMock.mockReset();
    getVirtualPbxStatusMock.mockReset();
    updateVirtualPbxChannelMock.mockReset();
    deleteVirtualPbxChannelMock.mockReset();
    routerPushMock.mockReset();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    getVirtualPbxStatusMock.mockResolvedValue(statusPayload);
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
    deleteVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('updates an existing Virtual PBX channel through local commit only', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    wrapper.vm.virtualPbxForm.connectionPassword = 'rotated-secret';
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      42,
      {
        provider_kind: 'sipuni',
        channel_name: 'Virtual PBX',
        display_phone_number: '+77271234567',
        provider_account_number: '3100000',
        ingress_number: '3100000',
        connection: {
          host: 'sip.provider.local',
          port: '5060',
          transport: 'udp',
          username: 'trunk-user',
          password: 'rotated-secret',
        },
        routing: {
          mode: 'operator',
          fallback_mode: 'reject',
          operator_agent_aor: 'sip:100@sip.provider.local',
        },
        metadata: {
          source: 'virtual_pbx_ui',
        },
      },
      { dryRun: false, remoteCommit: false }
    );
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_SUCCESS'
    );
  });

  it('blocks update when SIP port is not numeric', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    alertMock.mockClear();

    wrapper.vm.virtualPbxForm.connectionPort = '5060abc';
    await wrapper.vm.updateVirtualPbxChannel();

    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.INVALID'
    );
  });

  it('dry-runs delete before local delete and returns to inbox list', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    await wrapper.vm.deleteVirtualPbxChannel();
    await flushPromises();

    expect(deleteVirtualPbxChannelMock).toHaveBeenNthCalledWith(1, 42, {
      confirm: true,
      dryRun: true,
      remoteCommit: false,
    });
    expect(window.confirm).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.DELETE_CONFIRM'
    );
    expect(deleteVirtualPbxChannelMock).toHaveBeenNthCalledWith(2, 42, {
      confirm: true,
      dryRun: false,
      remoteCommit: false,
    });
    expect(routerPushMock).toHaveBeenCalledWith({
      name: 'settings_inbox_list',
      params: { accountId: 530 },
    });
  });
});
