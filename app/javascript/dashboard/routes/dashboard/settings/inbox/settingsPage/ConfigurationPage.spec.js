import { flushPromises, shallowMount } from '@vue/test-utils';

import ConfigurationPage from './ConfigurationPage.vue';

const alertMock = vi.hoisted(() => vi.fn());
const getVirtualPbxStatusMock = vi.hoisted(() => vi.fn());
const getVirtualPbxProvisioningPlanMock = vi.hoisted(() => vi.fn());
const provisionVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const reconcileVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const getVirtualPbxProvisioningRunsMock = vi.hoisted(() => vi.fn());
const updateVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const storeDispatchMock = vi.hoisted(() => vi.fn());
const copyTextToClipboardMock = vi.hoisted(() => vi.fn());

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

vi.mock('shared/helpers/clipboard', () => ({
  copyTextToClipboard: copyTextToClipboardMock,
}));

const virtualPbxDisplayNumber = '+10000000000';

const baseInbox = {
  id: 42,
  name: 'Virtual PBX',
  channel_type: 'Channel::Voice',
  provider: 'sipuni',
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
        remote_mutations: 'disabled',
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
        remote_mutations: 'disabled',
      },
      routing: {
        mode: 'operator',
        fallback_mode: 'reject',
        operator_distribution_mode: 'broadcast',
        operator_target_configured: true,
      },
      employees: [
        {
          id: 301,
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
        remote_commit_allowed: false,
      },
      warnings: [],
    },
    warnings: [],
    errors: [],
  },
};

const buildWrapper = ({ inbox = baseInbox } = {}) =>
  shallowMount(ConfigurationPage, {
    props: {
      inbox,
    },
    global: {
      mocks: {
        $t: key => key,
        $store: {
          dispatch: storeDispatchMock,
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
    storeDispatchMock.mockReset();
    copyTextToClipboardMock.mockReset();
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
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
    window.chatwootConfig = { hostURL: 'https://dev.one-link.kz' };
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
          operator_distribution_mode: 'broadcast',
        },
        connection: {
          host: 'ats01.kz.sipuni.com',
        },
        profiles: [
          {
            id: 301,
            profile_kind: 'human_operator',
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
      { dryRun: false, remoteCommit: false }
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

  it('does not overwrite handled-call visibility when technical settings are saved', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    wrapper.vm.virtualPbxForm.showCallsHandledByOtherOperators = true;

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(
      updateVirtualPbxChannelMock.mock.calls[0][1].routing
    ).not.toHaveProperty('show_calls_handled_by_other_operators');
  });

  it('keeps handled-call visibility out of technical configuration', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    const visibilityToggle = wrapper
      .findAllComponents({ name: 'SettingsToggleSection' })
      .find(
        component =>
          component.props('header') ===
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.HANDLED_CALL_VISIBILITY.LABEL'
      );

    expect(visibilityToggle).toBeUndefined();
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
            profile_kind: 'human_operator',
            user_id: 8,
            internal_extension: '208',
            sip_username: 'agent-208',
            sip_password: 'secret-208',
            enabled: true,
          },
        ],
      }),
      { dryRun: false, remoteCommit: false }
    );
  });

  it('saves a voice agent SIP profile without a OneLink employee', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

    wrapper.vm.virtualPbxForm.profiles = [
      {
        clientId: 'voice-agent-row',
        profileKind: 'voice_agent',
        userId: '',
        internalExtension: '9098',
        sipUsername: 'ai-agent-9098',
        sipPassword: 'secret-9098',
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
            profile_kind: 'voice_agent',
            internal_extension: '9098',
            sip_username: 'ai-agent-9098',
            sip_password: 'secret-9098',
            enabled: true,
          },
        ],
      }),
      { dryRun: false, remoteCommit: false }
    );
  });

  it('blocks multiple voice agent SIP profiles before save', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();
    alertMock.mockClear();

    wrapper.vm.virtualPbxForm.profiles = [
      {
        clientId: 'voice-agent-row-1',
        profileKind: 'voice_agent',
        internalExtension: '9098',
        sipUsername: 'ai-agent-9098',
        sipPassword: 'secret-9098',
        enabled: true,
      },
      {
        clientId: 'voice-agent-row-2',
        profileKind: 'voice_agent',
        internalExtension: '9099',
        sipUsername: 'ai-agent-9099',
        sipPassword: 'secret-9099',
        enabled: true,
      },
    ];
    await wrapper.vm.updateVirtualPbxChannel();

    expect(updateVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.VOICE_AGENT_UNIQUE'
    );
  });

  it('disables voice agent selection on other SIP profiles when one is already selected', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    wrapper.vm.virtualPbxForm.profiles = [
      {
        clientId: 'voice-agent-row',
        profileKind: 'voice_agent',
        internalExtension: '9098',
        sipUsername: 'ai-agent-9098',
        sipPassword: 'secret-9098',
        enabled: true,
      },
      {
        clientId: 'operator-row',
        profileKind: 'human_operator',
        userId: 8,
        internalExtension: '208',
        sipUsername: 'agent-208',
        sipPassword: 'secret-208',
        enabled: true,
      },
    ];

    expect(
      wrapper.vm.isVirtualPbxVoiceAgentToggleDisabled(
        wrapper.vm.virtualPbxForm.profiles[0],
        0
      )
    ).toBe(false);
    expect(
      wrapper.vm.isVirtualPbxVoiceAgentToggleDisabled(
        wrapper.vm.virtualPbxForm.profiles[1],
        1
      )
    ).toBe(true);

    wrapper.vm.virtualPbxForm.profiles[0].profileKind = 'human_operator';

    expect(
      wrapper.vm.isVirtualPbxVoiceAgentToggleDisabled(
        wrapper.vm.virtualPbxForm.profiles[1],
        1
      )
    ).toBe(false);
  });

  it('saves a Sipuni webhook token on the inbox provider config', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'sipuni',
        provider_config: {
          provider_kind: 'sipuni',
          existing_setting: 'keep-me',
          sipuni_events_webhook_token: 'old-token',
        },
      },
    });
    await flushPromises();

    expect(wrapper.vm.sipuniWebhookUrl).toBe(
      'https://dev.one-link.kz/sipuni/events/old-token'
    );

    wrapper.vm.sipuniWebhookToken = 'new-token';
    await wrapper.vm.updateSipuniWebhookToken();
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 42,
      formData: false,
      channel: {
        provider_config: {
          provider_kind: 'sipuni',
          existing_setting: 'keep-me',
          sipuni_events_webhook_token: 'new-token',
        },
      },
    });
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_SUCCESS'
    );
  });

  it('copies the Sipuni webhook URL for provider setup', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'sipuni',
        provider_config: {
          sipuni_events_webhook_token: 'saved-token',
        },
      },
    });
    await flushPromises();

    await wrapper.vm.copySipuniWebhookUrl();

    expect(copyTextToClipboardMock).toHaveBeenCalledWith(
      'https://dev.one-link.kz/sipuni/events/saved-token'
    );
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIPUNI_WEBHOOK_COPY_SUCCESS'
    );
  });

  it('renders Sipuni settings as employee SIP assignments without technical provider fields', async () => {
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
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_DISTRIBUTION.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.PROVIDER_CONNECTION'
    );
    expect(wrapper.text()).not.toContain(
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

  it('treats a native Sipuni voice inbox as Virtual PBX settings', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'sipuni',
      },
    });
    await flushPromises();

    expect(getVirtualPbxStatusMock).toHaveBeenCalledWith(42);
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_TITLE'
    );
  });

  it('treats a native Binotel voice inbox as Virtual PBX settings', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'binotel',
            provider_label: 'Binotel',
          },
          connection: {
            provider_kind: 'binotel',
            provider_label: 'Binotel',
            display_name: 'Binotel line',
            host: 'sip53.binotel.com',
          },
        },
      },
    });
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'binotel',
      },
    });
    await flushPromises();

    expect(getVirtualPbxStatusMock).toHaveBeenCalledWith(42);
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.FONOSTER_TITLE'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.PROVIDER_CONNECTION'
    );
  });

  it('renders Asterisk analog direct SIP fields and saves locally', async () => {
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
            outbound_dial_format: 'strip_plus',
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
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).toContain(
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
        metadata: {
          source: 'virtual_pbx_ui',
          outbound_dial_format: 'strip_plus',
        },
        profiles: [
          {
            profile_kind: 'human_operator',
            user_id: 7,
            internal_extension: '9098',
            sip_username: 'must-not-render',
            enabled: true,
          },
        ],
      }),
      { dryRun: false, remoteCommit: false }
    );
  });

  it('renders Beeline SIP domain and proxy fields and preserves the fixed transport contract', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'beeline',
            provider_label: 'Beeline Cloud PBX',
          },
          connection: {
            provider_kind: 'beeline',
            provider_label: 'Beeline Cloud PBX',
            host: 'cloudpbx.beeline.kz',
            port: 5060,
            transport: 'udp',
            sip_domain: 'vpbx-company-test.cloudpbx.beeline.kz',
            outbound_proxy: '46.227.186.231:6050',
            codec: 'pcma',
          },
        },
      },
    });
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'beeline',
      },
    });
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.SIP_DOMAIN.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_PROXY.LABEL'
    );

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        provider_kind: 'beeline',
        connection: {
          host: 'cloudpbx.beeline.kz',
          port: '5060',
          transport: 'udp',
          sip_domain: 'vpbx-company-test.cloudpbx.beeline.kz',
          outbound_proxy: '46.227.186.231:6050',
          codec: 'pcma',
        },
      }),
      { dryRun: false, remoteCommit: false }
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

  it('runs the local Janus SIP provisioning action through the product API', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    alertMock.mockClear();

    await wrapper.vm.provisionVirtualPbxChannel();
    await flushPromises();

    expect(provisionVirtualPbxChannelMock).toHaveBeenCalledWith(42, {
      remoteCommit: false,
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

describe('ConfigurationPage WhatsApp coexistence synchronization', () => {
  const coexistenceInbox = {
    id: 84,
    name: 'WhatsApp coexistence',
    channel_type: 'Channel::Whatsapp',
    provider: 'whatsapp_cloud',
    provider_config: {
      source: 'embedded_signup',
      embedded_signup_flow: 'coexistence',
      coexistence_sync: {
        state: 'history_failed',
        history_progress: 75,
        last_error: 'History import needs recovery',
        history_failed_messages: [{ id: 'wamid.failed' }],
      },
    },
    members: [],
  };

  it('shows status, progress, failure count, and recovery action', () => {
    const wrapper = buildWrapper({ inbox: coexistenceInbox });

    expect(
      wrapper.find('[data-testid="whatsapp-coexistence-sync-status"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="whatsapp-coexistence-sync-recover"]').exists()
    ).toBe(true);
    expect(wrapper.vm.coexistenceSyncStateLabel).toBe(
      'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_COEXISTENCE_SYNC_STATES.HISTORY_FAILED'
    );
    expect(wrapper.vm.coexistenceSyncProgress).toBe(75);
    expect(wrapper.vm.coexistenceSyncFailureCount).toBe(1);
    expect(wrapper.text()).toContain('History import needs recovery');
  });

  it('does not offer recovery for a completed synchronization', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...coexistenceInbox,
        provider_config: {
          ...coexistenceInbox.provider_config,
          coexistence_sync: { state: 'completed', history_progress: 100 },
        },
      },
    });

    expect(
      wrapper.find('[data-testid="whatsapp-coexistence-sync-status"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="whatsapp-coexistence-sync-recover"]').exists()
    ).toBe(false);
  });
});
