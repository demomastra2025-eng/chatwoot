import { flushPromises, shallowMount } from '@vue/test-utils';
import enInboxMgmt from 'dashboard/i18n/locale/en/inboxMgmt.json';
import ruInboxMgmt from 'dashboard/i18n/locale/ru/inboxMgmt.json';

import ConfigurationPage from './ConfigurationPage.vue';

const enTe = key =>
  typeof key.split('.').reduce((node, part) => node?.[part], enInboxMgmt) ===
  'string';

const ruTe = key =>
  typeof key.split('.').reduce((node, part) => node?.[part], ruInboxMgmt) ===
  'string';

const alertMock = vi.hoisted(() => vi.fn());
const getVirtualPbxStatusMock = vi.hoisted(() => vi.fn());
const getVirtualPbxProvisioningPlanMock = vi.hoisted(() => vi.fn());
const provisionVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const reconcileVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const getVirtualPbxProvisioningRunsMock = vi.hoisted(() => vi.fn());
const updateVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const probeVirtualPbxChannelCapacityMock = vi.hoisted(() => vi.fn());
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
    probeVirtualPbxChannelCapacity: probeVirtualPbxChannelCapacityMock,
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
      configuration_version: 7,
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

const buildWrapper = ({ inbox = baseInbox, te, storeGetters = {} } = {}) =>
  shallowMount(ConfigurationPage, {
    props: {
      inbox,
    },
    global: {
      mocks: {
        $t: key => key,
        ...(te ? { $te: te } : {}),
        $store: {
          dispatch: storeDispatchMock,
          getters: {
            'inboxes/getInboxes': [],
            ...storeGetters,
          },
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
        expected_configuration_version: 7,
        provider_kind: 'sipuni',
        channel_name: 'Virtual PBX',
        display_phone_number: virtualPbxDisplayNumber,
        routing: {
          mode: 'operator',
          fallback_mode: 'reject',
          operator_distribution_mode: 'broadcast',
          max_call_duration_seconds: 1800,
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

  it('never sends the retired handled-call visibility setting when technical settings are saved', async () => {
    const wrapper = buildWrapper();
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

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

  it('saves a Binotel webhook token on the inbox provider config', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'binotel',
        provider_config: {
          provider_kind: 'binotel',
          existing_setting: 'keep-me',
          binotel_events_webhook_token: 'old-token',
          binotel_webhook_token: 'legacy-token',
        },
      },
    });
    await flushPromises();

    expect(wrapper.vm.binotelWebhookUrl).toBe(
      'https://dev.one-link.kz/binotel/events/old-token'
    );

    wrapper.vm.binotelWebhookToken = 'new-token';
    await wrapper.vm.updateBinotelWebhookToken();
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 42,
      formData: false,
      channel: {
        provider_config: {
          provider_kind: 'binotel',
          existing_setting: 'keep-me',
          binotel_events_webhook_token: 'new-token',
        },
      },
    });
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_SUCCESS'
    );
  });

  it('copies the Binotel webhook URL for provider setup', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'binotel',
        provider_config: {
          binotel_events_webhook_token: 'saved-token',
        },
      },
    });
    await flushPromises();

    await wrapper.vm.copyBinotelWebhookUrl();

    expect(copyTextToClipboardMock).toHaveBeenCalledWith(
      'https://dev.one-link.kz/binotel/events/saved-token'
    );
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BINOTEL_WEBHOOK_COPY_SUCCESS'
    );
  });

  it('saves a Beeline webhook token and Cloud PBX API token on the inbox provider config', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'beeline',
        provider_config: {
          provider_kind: 'beeline',
          existing_setting: 'keep-me',
          beeline_events_webhook_token: 'old-beeline-token',
          beeline_webhook_token: 'legacy-beeline-token',
        },
      },
    });
    await flushPromises();

    expect(wrapper.vm.beelineWebhookUrl).toBe(
      'https://dev.one-link.kz/beeline/events/old-beeline-token'
    );
    expect(enTe('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TITLE')).toBe(
      true
    );
    expect(ruTe('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TITLE')).toBe(
      true
    );
    expect(enTe('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_API_TOKEN')).toBe(
      true
    );
    expect(ruTe('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_API_TOKEN')).toBe(
      true
    );

    wrapper.vm.beelineWebhookToken = 'new-beeline-token';
    wrapper.vm.beelineApiToken = 'mpbx-secret-token';
    await wrapper.vm.updateBeelineWebhookToken();
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 42,
      formData: false,
      channel: {
        provider_config: {
          provider_kind: 'beeline',
          existing_setting: 'keep-me',
          beeline_events_webhook_token: 'new-beeline-token',
          beeline_api_token: 'mpbx-secret-token',
        },
      },
    });
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_SUCCESS'
    );
  });

  it('copies the Beeline webhook URL for provider setup', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'beeline',
        provider_config: {
          beeline_events_webhook_token: 'saved-beeline-token',
        },
      },
    });
    await flushPromises();

    await wrapper.vm.copyBeelineWebhookUrl();

    expect(copyTextToClipboardMock).toHaveBeenCalledWith(
      'https://dev.one-link.kz/beeline/events/saved-beeline-token'
    );
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_COPY_SUCCESS'
    );
  });

  it('preserves an already configured Beeline API token when regenerating the webhook token with a blank password input', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'beeline',
        provider_config: {
          provider_kind: 'beeline',
          beeline_events_webhook_token: 'old-beeline-token',
          beeline_api_token: 'already-saved-secret',
        },
      },
    });
    await flushPromises();

    expect(wrapper.vm.beelineApiTokenConfigured).toBe(true);
    expect(wrapper.vm.beelineApiToken).toBe('');

    wrapper.vm.generateBeelineWebhookToken();
    const generatedToken = wrapper.vm.beelineWebhookToken;
    expect(generatedToken).not.toBe('old-beeline-token');

    await wrapper.vm.updateBeelineWebhookToken();
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 42,
      formData: false,
      channel: {
        provider_config: {
          provider_kind: 'beeline',
          beeline_events_webhook_token: generatedToken,
          beeline_api_token: 'already-saved-secret',
        },
      },
    });
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

  it('requires explicit confirmation before applying Wazo remote provisioning', async () => {
    const confirmMock = vi.spyOn(window, 'confirm').mockReturnValue(false);
    getVirtualPbxStatusMock.mockResolvedValueOnce({
      payload: {
        ...statusPayload.payload,
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'wazo',
          },
        },
      },
    });
    const wrapper = buildWrapper({
      inbox: { ...baseInbox, provider: 'wazo' },
    });
    await flushPromises();
    provisionVirtualPbxChannelMock.mockClear();

    await wrapper.vm.provisionVirtualPbxChannel();
    expect(provisionVirtualPbxChannelMock).not.toHaveBeenCalled();

    confirmMock.mockReturnValue(true);
    await wrapper.vm.provisionVirtualPbxChannel();
    await flushPromises();

    expect(provisionVirtualPbxChannelMock).toHaveBeenCalledWith(42, {
      remoteCommit: true,
      includeDiagnostics: false,
    });
    confirmMock.mockRestore();
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

describe('ConfigurationPage Virtual PBX save feedback and Beeline dialing', () => {
  beforeEach(() => {
    alertMock.mockReset();
    getVirtualPbxStatusMock.mockReset();
    getVirtualPbxProvisioningRunsMock.mockReset();
    updateVirtualPbxChannelMock.mockReset();
    storeDispatchMock.mockReset();
    getVirtualPbxStatusMock.mockResolvedValue(statusPayload);
    getVirtualPbxProvisioningRunsMock.mockResolvedValue({
      payload: { provisioning_runs: [] },
    });
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
  });

  it('names the channel that already uses the number', async () => {
    updateVirtualPbxChannelMock.mockResolvedValue({
      payload: {
        valid: false,
        errors: [
          {
            code: 'display_phone_number_taken',
            message:
              'display_phone_number is already used by another voice channel',
            conflict: { inbox_id: 5248, inbox_name: 'Sip', same_account: true },
          },
        ],
      },
    });
    const wrapper = buildWrapper({ te: enTe });
    await flushPromises();

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ERRORS.NUMBER_TAKEN_BY_INBOX'
    );
    expect(alertMock).not.toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.UPDATE_SUCCESS'
    );
  });

  it('explains a stale configuration conflict', async () => {
    updateVirtualPbxChannelMock.mockRejectedValue({
      message: 'Request failed with status code 409',
      response: {
        status: 409,
        data: {
          code: 'VIRTUAL_PBX_CONFIGURATION_STALE',
          error: 'Virtual PBX configuration changed; reload it before saving',
        },
      },
    });
    const wrapper = buildWrapper({ te: enTe });
    await flushPromises();

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ERRORS.VIRTUAL_PBX_CONFIGURATION_STALE'
    );
  });

  it('offers Beeline outbound dial formats and saves +7XXXXXXXXXX by default', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ...statusPayload.payload,
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'beeline',
          },
          connection: {
            provider_kind: 'beeline',
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
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
    const wrapper = buildWrapper({
      inbox: { ...baseInbox, provider: 'beeline' },
    });
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.LABEL'
    );
    expect(
      wrapper.vm.virtualPbxOutboundDialFormatOptions.map(option => option.value)
    ).toEqual(['e164_plus', 'kz_trunk', 'strip_plus']);
    expect(wrapper.vm.virtualPbxForm.outboundDialFormat).toBe('e164_plus');

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(
      updateVirtualPbxChannelMock.mock.calls[0][1].metadata.outbound_dial_format
    ).toBe('e164_plus');
  });

  it('localizes provisioning errors listed in the status panel', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ...statusPayload.payload,
        errors: [
          {
            code: 'beeline_outbound_proxy_required',
            message: 'raw-proxy-message',
          },
        ],
      },
    });
    const wrapper = buildWrapper({ te: enTe });
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ERRORS.BEELINE_OUTBOUND_PROXY_REQUIRED'
    );
    expect(wrapper.text()).not.toContain('raw-proxy-message');
  });

  it('locks providerKind, Wazo SIP host, carrierKind, trunkDomain, and trunkHost for an Altel channel and surfaces auto-detected channel limit', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ...statusPayload.payload,
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'wazo',
            carrier_kind: 'altel',
          },
          connection: {
            provider_kind: 'wazo',
            carrier_kind: 'altel',
            host: '',
            port: 5060,
            transport: 'udp',
            max_channels: 5,
            detected_channel_limit: 2,
            last_channel_limit_hit_at: '2026-04-17T10:00:00Z',
            trunk_username: 'f9bOCzgF',
            trunk_password_configured: true,
          },
        },
      },
    });

    const wrapper = buildWrapper({
      inbox: { ...baseInbox, provider: 'wazo' },
    });
    await flushPromises();

    expect(wrapper.vm.virtualPbxForm.connectionHost).toBe('188.241.217.162');
    expect(wrapper.vm.virtualPbxForm.carrierKind).toBe('altel');
    expect(wrapper.vm.virtualPbxForm.trunkDomain).toBe('astpbx.tele2.kz');
    expect(wrapper.vm.virtualPbxForm.trunkHost).toBe('91.185.24.71');
    expect(wrapper.vm.virtualPbxForm.detectedChannelLimit).toBe(2);

    expect(
      wrapper
        .find('[data-testid="virtual-pbx-provider-kind"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper
        .find('[data-testid="virtual-pbx-connection-host"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper
        .find('[data-testid="virtual-pbx-carrier-kind"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper
        .find('[data-testid="virtual-pbx-trunk-domain"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper
        .find('[data-testid="virtual-pbx-trunk-host"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper.find('[data-testid="virtual-pbx-carrier-badge"]').attributes('src')
    ).toBe('/integrations/channels/badges/altel.svg');

    expect(
      wrapper.find('[data-testid="virtual-pbx-detected-channel-limit"]').exists()
    ).toBe(true);
    await wrapper
      .find('[data-testid="virtual-pbx-apply-detected-limit"]')
      .trigger('click');
    expect(wrapper.vm.virtualPbxForm.maxChannels).toBe(2);
  });

  it('renders and saves the Visual Inbound & Outbound Call Routing Builder across Virtual PBX channels', async () => {
    const wrapper = buildWrapper();
    await flushPromises();

    expect(wrapper.find('[data-testid="call-routing-builder"]').exists()).toBe(
      true
    );

    await wrapper
      .find('[data-testid="call-routing-schedule-mode"]')
      .setValue('business_hours');
    await wrapper
      .find('[data-testid="call-routing-ringtone"]')
      .setValue('classic');
    wrapper.vm.toggleCallRoutingGroupUser(
      wrapper.vm.callRoutingForm.inbound.groups[0],
      7
    );
    wrapper.vm.addCallRoutingGroup();
    wrapper.vm.callRoutingForm.inbound.groups[1].name = 'Sales';
    wrapper.vm.callRoutingForm.inbound.groups[1].strategy = 'round_robin';
    wrapper.vm.toggleCallRoutingGroupUser(
      wrapper.vm.callRoutingForm.inbound.groups[1],
      8
    );

    await wrapper
      .find('[data-testid="call-routing-tab-outbound"]')
      .trigger('click');
    await wrapper
      .find('[data-testid="call-routing-outbound-access-mode"]')
      .setValue('selected_operators');
    wrapper.vm.toggleCallRoutingOutboundUser(7);

    updateVirtualPbxChannelMock.mockClear();
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    const savedRouting = updateVirtualPbxChannelMock.mock.calls[0][1].routing;
    expect(savedRouting.call_routing).toMatchObject({
      inbound: {
        schedule_mode: 'business_hours',
        ringtone: 'classic',
        groups: [
          expect.objectContaining({
            strategy: 'broadcast',
            user_ids: [7],
          }),
          expect.objectContaining({
            name: 'Sales',
            strategy: 'round_robin',
            user_ids: [8],
          }),
        ],
      },
      outbound: {
        access_mode: 'selected_operators',
        allowed_user_ids: [7],
      },
    });
  });

  it('renders and saves the Visual Call Routing Builder for WhatsApp Calling', async () => {
    const whatsappCallingInbox = {
      id: 95,
      name: 'WhatsApp Calling',
      channel_type: 'Channel::Whatsapp',
      provider: 'whatsapp_cloud',
      provider_config: {
        calling_enabled: true,
      },
      members: [{ id: 7, name: 'Ada Agent' }],
    };

    const wrapper = buildWrapper({ inbox: whatsappCallingInbox });
    await flushPromises();

    expect(
      wrapper.find('[data-testid="whatsapp-call-routing-builder"]').exists()
    ).toBe(true);

    wrapper.vm.callRoutingForm.inbound.schedule_mode = 'business_hours';
    wrapper.vm.callRoutingForm.inbound.fallback_action = 'ai';
    await wrapper.vm.saveWhatsAppCallRouting();
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith(
      'inboxes/updateInbox',
      expect.objectContaining({
        id: 95,
        formData: false,
        channel: {
          provider_config: expect.objectContaining({
            calling_enabled: true,
            call_routing: expect.objectContaining({
              inbound: expect.objectContaining({
                schedule_mode: 'business_hours',
                fallback_action: 'ai',
              }),
            }),
          }),
        },
      })
    );
  });

  it('configures missed-call WhatsApp follow-up with approved templates for official WABA channels and custom text for personal WhatsApp channels', async () => {
    const whatsappCloudInbox = {
      id: 201,
      name: 'WhatsApp Cloud Official',
      channel_type: 'Channel::Whatsapp',
      provider: 'whatsapp_cloud',
      message_templates: [
        { name: 'missed_call_followup', status: 'APPROVED', language: 'ru' },
        { name: 'draft_template', status: 'PENDING', language: 'ru' },
      ],
    };
    const whatsappPersonalInbox = {
      id: 202,
      name: 'WhatsApp Web Personal',
      channel_type: 'Channel::WhatsappWeb',
      provider: 'baileys',
    };

    const wrapper = buildWrapper({
      storeGetters: {
        'inboxes/getInboxes': [whatsappCloudInbox, whatsappPersonalInbox],
      },
    });
    await flushPromises();

    await wrapper
      .find('[data-testid="call-routing-whatsapp-followup-enabled"]')
      .setValue(true);
    expect(
      wrapper.find('[data-testid="call-routing-whatsapp-followup-panel"]').exists()
    ).toBe(true);

    // Select official WABA channel -> template selector appears, custom message hidden
    await wrapper
      .find('[data-testid="call-routing-whatsapp-inbox"]')
      .setValue('201');
    expect(
      wrapper.find('[data-testid="call-routing-whatsapp-template"]').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-testid="call-routing-whatsapp-custom-message"]')
        .exists()
    ).toBe(false);
    expect(wrapper.vm.selectedWhatsappFollowupTemplates).toEqual([
      { name: 'missed_call_followup', status: 'APPROVED', language: 'ru' },
    ]);
    await wrapper
      .find('[data-testid="call-routing-whatsapp-template"]')
      .setValue('missed_call_followup');

    // Switch to personal WhatsApp channel -> custom message input appears
    await wrapper
      .find('[data-testid="call-routing-whatsapp-inbox"]')
      .setValue('202');
    expect(
      wrapper.find('[data-testid="call-routing-whatsapp-template"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .find('[data-testid="call-routing-whatsapp-custom-message"]')
        .exists()
    ).toBe(true);
    await wrapper
      .find('[data-testid="call-routing-whatsapp-custom-message"]')
      .setValue('Здравствуйте! Пропустили ваш звонок, напишите нам здесь.');
    await wrapper
      .find('[data-testid="call-routing-whatsapp-cooldown"]')
      .setValue('45');
    await wrapper
      .find('[data-testid="call-routing-show-extended-call-card"]')
      .setValue(false);

    updateVirtualPbxChannelMock.mockClear();
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    const savedRouting = updateVirtualPbxChannelMock.mock.calls[0][1].routing;
    expect(savedRouting.call_routing.show_extended_call_card).toBe(false);
    expect(savedRouting.call_routing.inbound.whatsapp_followup).toEqual({
      enabled: true,
      inbox_id: 202,
      template_name: 'missed_call_followup',
      template_language: 'ru',
      custom_message:
        'Здравствуйте! Пропустили ваш звонок, напишите нам здесь.',
      cooldown_minutes: 45,
    });
  });

  it('probes Wazo trunk channel capacity, updates maxChannels and AI concurrency badge, and forces OneLink routing authority for Wazo', async () => {
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: {
        ...statusPayload.payload,
        ui_config: {
          ...statusPayload.payload.ui_config,
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'wazo',
            carrier_kind: 'altel',
          },
          connection: {
            provider_kind: 'wazo',
            carrier_kind: 'altel',
            host: '188.241.217.162',
            port: 5060,
            transport: 'udp',
            max_channels: 2,
            ai_max_concurrent_calls: 2,
            trunk_username: 'f9bOCzgF',
            trunk_password_configured: true,
          },
        },
      },
    });
    probeVirtualPbxChannelCapacityMock.mockResolvedValue({
      payload: {
        ui_config: {
          ...statusPayload.payload.ui_config,
          configuration_version: 'v-after-probe-42',
          channel: {
            ...statusPayload.payload.ui_config.channel,
            provider_kind: 'wazo',
            carrier_kind: 'altel',
          },
          connection: {
            provider_kind: 'wazo',
            carrier_kind: 'altel',
            host: '188.241.217.162',
            port: 5060,
            transport: 'udp',
            max_channels: 2,
            detected_channel_limit: 4,
            ai_max_concurrent_calls: 4,
            trunk_username: 'f9bOCzgF',
            trunk_password_configured: true,
          },
        },
        channel_capacity_probe: {
          detected_channel_limit: 4,
          ai_max_concurrent_calls: 4,
          answered: false,
          billed_amount_kzt: 0,
          probed_at: '2026-04-17T12:00:00Z',
          detection_source: 'active_probe',
        },
      },
    });
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });

    const wrapper = buildWrapper({
      inbox: { ...baseInbox, provider: 'wazo' },
    });
    await flushPromises();

    expect(
      wrapper.find('[data-testid="virtual-pbx-ai-concurrency-badge"]').exists()
    ).toBe(true);
    expect(wrapper.vm.effectiveAiMaxConcurrentCalls).toBe(2);
    expect(
      wrapper.find('[data-testid="call-routing-wazo-onelink-badge"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="call-routing-authority-selector"]').exists()
    ).toBe(false);

    await wrapper.vm.probeVirtualPbxChannelCapacity();
    await flushPromises();

    expect(probeVirtualPbxChannelCapacityMock).toHaveBeenCalledWith(42);
    expect(wrapper.vm.virtualPbxForm.detectedChannelLimit).toBe(4);
    expect(wrapper.vm.virtualPbxForm.maxChannels).toBe(4);
    expect(wrapper.vm.effectiveAiMaxConcurrentCalls).toBe(4);
    expect(wrapper.vm.virtualPbxForm.channelDetectionSource).toBe(
      'active_probe'
    );

    updateVirtualPbxChannelMock.mockClear();
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(
      updateVirtualPbxChannelMock.mock.calls[0][1]
        .expected_configuration_version
    ).toBe('v-after-probe-42');
    expect(
      updateVirtualPbxChannelMock.mock.calls[0][1].connection.max_channels
    ).toBe(4);
  });

  it('allows switching between external_pbx and onelink routing authority for external Cloud PBX providers and defines all routing/carrier i18n keys in EN and RU', async () => {
    const requiredKeys = [
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.TITLE',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.EXTERNAL_PBX',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.EXTERNAL_PBX_DESC',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.EXTERNAL_PBX_HINT',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.ONELINK',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.ONELINK_DESC',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.ONELINK_HINT',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.WAZO_ONELINK_BADGE',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CALL_ROUTING.ROUTING_AUTHORITY.WAZO_ALWAYS_ONELINK_HINT',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.PROBE_CHANNELS_BUTTON',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.PROBE_CHANNELS_SUCCESS',
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.AI_CONCURRENCY_BADGE',
    ];
    requiredKeys.forEach(key => {
      expect(enTe(key)).toBe(true);
      expect(ruTe(key)).toBe(true);
    });

    const wrapper = buildWrapper({
      inbox: { ...baseInbox, provider: 'sipuni' },
    });
    await flushPromises();

    expect(
      wrapper.find('[data-testid="call-routing-authority-selector"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="call-routing-wazo-onelink-badge"]').exists()
    ).toBe(false);
    expect(wrapper.vm.callRoutingForm.inbound.routing_authority).toBe(
      'onelink'
    );

    await wrapper
      .find('[data-testid="call-routing-authority-external-pbx"]')
      .trigger('click');

    expect(wrapper.vm.callRoutingForm.inbound.routing_authority).toBe(
      'external_pbx'
    );
    expect(wrapper.vm.isExternalPbxRoutingAuthority).toBe(true);
    expect(
      wrapper.find('[data-testid="call-routing-schedule-mode"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .find('[data-testid="call-routing-whatsapp-followup-enabled"]')
        .exists()
    ).toBe(true);

    updateVirtualPbxChannelMock.mockClear();
    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    const savedRouting = updateVirtualPbxChannelMock.mock.calls[0][1].routing;
    expect(savedRouting.call_routing.inbound.routing_authority).toBe(
      'external_pbx'
    );
  });
});

