import { flushPromises, shallowMount } from '@vue/test-utils';

import ConfigurationPage from './ConfigurationPage.vue';

const alertMock = vi.hoisted(() => vi.fn());
const getVirtualPbxStatusMock = vi.hoisted(() => vi.fn());
const getVirtualPbxProvisioningPlanMock = vi.hoisted(() => vi.fn());
const provisionVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const reconcileVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const getVirtualPbxProvisioningRunsMock = vi.hoisted(() => vi.fn());
const updateVirtualPbxChannelMock = vi.hoisted(() => vi.fn());

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    getVirtualPbxStatus: getVirtualPbxStatusMock,
    getVirtualPbxProvisioningPlan: getVirtualPbxProvisioningPlanMock,
    provisionVirtualPbxChannel: provisionVirtualPbxChannelMock,
    reconcileVirtualPbxChannel: reconcileVirtualPbxChannelMock,
    getVirtualPbxProvisioningRuns: getVirtualPbxProvisioningRunsMock,
    updateVirtualPbxChannel: updateVirtualPbxChannelMock,
  },
}));

const virtualPbxDisplayNumber = '+10000000000';

const baseInbox = {
  id: 42,
  name: 'Virtual PBX',
  channel_type: 'Channel::Voice',
  provider: 'fonoster',
  phone_number: virtualPbxDisplayNumber,
  provider_config: {},
  members: [
    { id: 7, name: 'Ada Agent' },
    { id: 8, name: 'Grace Agent' },
  ],
};

const statusPayload = {
  payload: {
    ui_config: {
      inbox_id: 42,
      status: {
        ready: true,
        read_only: false,
        remote_mutations: 'requires_approval',
      },
      channel: {
        name: 'Virtual PBX',
        provider_kind: 'sipuni',
        provider_label: 'Sipuni',
        display_phone_number: virtualPbxDisplayNumber,
      },
      connection: {
        provider_kind: 'sipuni',
        provider_label: 'Sipuni',
        display_name: 'Sipuni trunk',
        provider_number: '3100000',
        host: 'ats01.kz.sipuni.com',
        port: 5060,
        transport: 'udp',
        configured: true,
        status: 'draft',
        remote_mutations: 'requires_approval',
      },
      routing: {
        mode: 'operator',
        fallback_mode: 'reject',
        operator_target_configured: true,
      },
      employees: [
        {
          user_id: 7,
          user_name: 'Ada Agent',
          internal_extension: '100',
          sip_username: 'agent-100',
          sip_password_configured: true,
          enabled: true,
          access_configured: true,
        },
      ],
      permissions: {
        editable: true,
        deletable: true,
        remote_commit_allowed: true,
      },
      warnings: [],
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
    getVirtualPbxProvisioningPlanMock.mockReset();
    provisionVirtualPbxChannelMock.mockReset();
    reconcileVirtualPbxChannelMock.mockReset();
    getVirtualPbxProvisioningRunsMock.mockReset();
    updateVirtualPbxChannelMock.mockReset();
    getVirtualPbxStatusMock.mockResolvedValue(statusPayload);
    getVirtualPbxProvisioningPlanMock.mockResolvedValue({
      payload: {
        provisioning_plan: {
          status: 'dry_run_valid',
          remote_mutations: 'requires_approval',
          operations: [{ key: 'upsert_number', risk: 'requires_approval' }],
        },
      },
    });
    provisionVirtualPbxChannelMock.mockResolvedValue({
      payload: {
        status: 'succeeded',
        remote_commit: true,
        errors: [],
      },
    });
    reconcileVirtualPbxChannelMock.mockResolvedValue({
      payload: { status: 'requires_manual_reconcile', drift: [] },
    });
    getVirtualPbxProvisioningRunsMock.mockResolvedValue({
      payload: { provisioning_runs: [{ id: 1, status: 'blocked' }] },
    });
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('updates an existing Virtual PBX channel through local business fields only', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      42,
      {
        provider_kind: 'sipuni',
        channel_name: 'Virtual PBX',
        display_phone_number: virtualPbxDisplayNumber,
        routing: {
          mode: 'operator',
          fallback_mode: 'reject',
        },
        connection: {
          host: 'ats01.kz.sipuni.com',
        },
        profiles: [
          {
            user_id: 7,
            internal_extension: '100',
            sip_username: 'agent-100',
            enabled: true,
          },
        ],
        metadata: {
          source: 'virtual_pbx_ui',
        },
      },
      { dryRun: false, remoteCommit: true }
    );
    expect(
      JSON.stringify(updateVirtualPbxChannelMock.mock.calls[0][1])
    ).not.toContain('trunk');
    expect(
      JSON.stringify(updateVirtualPbxChannelMock.mock.calls[0][1])
    ).not.toContain('sip_password');
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_SUCCESS'
    );
  });

  it('saves employee SIP assignments from settings only', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

    wrapper.vm.virtualPbxForm.profiles = [
      {
        clientId: 'manual-row',
        userId: 8,
        internalExtension: '208',
        sipUsername: 'agent-208',
        sipPassword: 'secret-208',
        sipPasswordConfigured: false,
        enabled: true,
      },
    ];
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        profiles: [
          {
            user_id: 8,
            internal_extension: '208',
            sip_username: 'agent-208',
            sip_password: 'secret-208',
            enabled: true,
          },
        ],
      }),
      { dryRun: false, remoteCommit: true }
    );
  });

  it('renders Sipuni settings with host only and without default SIP internals', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.PROVIDER_CONNECTION'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.TRANSPORT.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.ROUTING_MODE'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_USERNAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.OPERATOR_AGENT_AOR'
    );
    expect(wrapper.text()).not.toContain('Sipuni trunk');
    expect(wrapper.text()).not.toContain('3100000');
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.DELETE_BUTTON'
    );
  });

  it('renders Asterisk analog employee extensions without SIP credential fields', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'asterisk_analog',
            provider_label: 'Asterisk analog',
          },
          connection: {
            provider_kind: 'asterisk_analog',
            provider_label: 'Asterisk analog',
            host: '10.77.0.5',
            port: 5070,
            transport: 'tcp',
          },
          employees: [
            {
              user_id: 7,
              user_name: 'Ada Agent',
              internal_extension: '9098',
              sip_username: 'must-not-render',
              sip_password_configured: true,
              enabled: true,
            },
          ],
        },
      },
    });
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
    );
    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        provider_kind: 'asterisk_analog',
        connection: {
          host: '10.77.0.5',
          port: '5070',
          transport: 'tcp',
        },
        profiles: [
          {
            user_id: 7,
            internal_extension: '9098',
            enabled: true,
          },
        ],
      }),
      { dryRun: false, remoteCommit: true }
    );
  });

  it('shows a masked placeholder for already configured employee SIP passwords', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    const passwordInput = wrapper.find('input[type="password"]');

    expect(passwordInput.attributes('placeholder')).toBe('********');
    expect(wrapper.vm.virtualPbxForm.profiles[0].sipPassword).toBe('');
    expect(wrapper.vm.virtualPbxForm.profiles[0].sipPasswordConfigured).toBe(
      true
    );
  });

  it('blocks incomplete employee extension rows before save', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    alertMock.mockClear();

    wrapper.vm.virtualPbxForm.profiles = [
      {
        clientId: 'partial-row',
        userId: 8,
        internalExtension: '',
        enabled: true,
      },
    ];
    await wrapper.vm.updateVirtualPbxChannel();

    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.REQUIRED'
    );
  });

  it('blocks incomplete employee SIP credential pairs before save', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    alertMock.mockClear();

    wrapper.vm.virtualPbxForm.profiles = [
      {
        clientId: 'partial-sip-row',
        userId: 8,
        internalExtension: '208',
        sipUsername: '',
        sipPassword: 'secret-208',
        sipPasswordConfigured: false,
        enabled: true,
      },
    ];
    await wrapper.vm.updateVirtualPbxChannel();

    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SIP_PAIR_REQUIRED'
    );
  });

  it('requires a new SIP password when an existing employee SIP username changes', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    alertMock.mockClear();

    wrapper.vm.virtualPbxForm.profiles[0].sipUsername = 'agent-101';
    await wrapper.vm.updateVirtualPbxChannel();

    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SIP_PAIR_REQUIRED'
    );
  });

  it('keeps Sipuni default port and transport out of the update payload', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

    wrapper.vm.virtualPbxForm.connectionPort = '5060abc';
    wrapper.vm.virtualPbxForm.connectionHost = 'internal.example';
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalled();
    expect(updateVirtualPbxChannelMock.mock.calls[0][1].connection).toEqual({
      host: 'internal.example',
    });
  });

  it('blocks invalid Asterisk analog connection port before save', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'asterisk_analog',
            provider_label: 'Asterisk analog',
          },
          connection: {
            provider_kind: 'asterisk_analog',
            provider_label: 'Asterisk analog',
            host: '10.77.0.5',
            port: 5070,
            transport: 'tcp',
          },
        },
      },
    });
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    alertMock.mockClear();

    wrapper.vm.virtualPbxForm.connectionPort = '99999';
    await wrapper.vm.updateVirtualPbxChannel();

    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.INVALID'
    );
  });

  it('loads a safe provisioning plan without diagnostics', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    alertMock.mockClear();

    await wrapper.vm.loadVirtualPbxProvisioningPlan();
    await flushPromises();

    expect(getVirtualPbxProvisioningPlanMock).toHaveBeenCalledWith(42, {
      operation: 'update',
      includeDiagnostics: false,
    });
    expect(wrapper.vm.virtualPbxProvisioningPlan.remote_mutations).toBe(
      'requires_approval'
    );
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISIONING_PLAN_READY'
    );
  });

  it('does not reload Virtual PBX data when the same inbox object is refreshed', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    getVirtualPbxStatusMock.mockClear();
    getVirtualPbxProvisioningRunsMock.mockClear();

    await wrapper.setProps({
      inbox: {
        ...baseInbox,
        name: 'Virtual PBX refreshed',
        members: [...baseInbox.members],
      },
    });
    await flushPromises();

    expect(getVirtualPbxStatusMock).not.toHaveBeenCalled();
    expect(getVirtualPbxProvisioningRunsMock).not.toHaveBeenCalled();
  });

  it('provisions the remote Fonoster/Routr resources through the product API', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    alertMock.mockClear();

    await wrapper.vm.provisionVirtualPbxChannel();
    await flushPromises();

    expect(provisionVirtualPbxChannelMock).toHaveBeenCalledWith(42, {
      remoteCommit: true,
      includeDiagnostics: false,
    });
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISION_SUCCESS'
    );
  });

  it('reconciles sync state through the product API', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    alertMock.mockClear();

    await wrapper.vm.reconcileVirtualPbxChannel();
    await flushPromises();

    expect(reconcileVirtualPbxChannelMock).toHaveBeenCalledWith(42, {
      includeDiagnostics: false,
    });
    expect(wrapper.vm.virtualPbxReconcileResult.status).toBe(
      'requires_manual_reconcile'
    );
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.RECONCILE_COMPLETE'
    );
  });
});
