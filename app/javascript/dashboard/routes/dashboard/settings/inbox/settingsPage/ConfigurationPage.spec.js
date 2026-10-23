import { flushPromises, shallowMount } from '@vue/test-utils';
import enInboxMgmt from 'dashboard/i18n/locale/en/inboxMgmt.json';
import ruInboxMgmt from 'dashboard/i18n/locale/ru/inboxMgmt.json';
import kkInboxMgmt from 'dashboard/i18n/locale/kk/inboxMgmt.json';

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

const buildWrapper = ({
  inbox = baseInbox,
  te,
  storeGetters = {},
  section = 'configuration',
} = {}) =>
  shallowMount(ConfigurationPage, {
    props: {
      inbox,
      section,
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
        // The real block is collapsed; the stub keeps its content visible so
        // the developer fields can be checked.
        DeveloperDetails: {
          template: '<div data-testid="developer-details"><slot /></div>',
        },
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

  it('saves Binotel API credentials and preserves existing secret when left blank', async () => {
    const wrapper = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'binotel',
        provider_config: {
          provider_kind: 'binotel',
          binotel_events_webhook_token: 'saved-token',
          binotel_api_key: 'clinic@example.com',
          binotel_api_secret_configured: true,
        },
      },
    });
    await flushPromises();

    expect(
      wrapper
        .find('[data-testid="binotel-api-secret-configured-hint"]')
        .exists()
    ).toBe(true);

    wrapper.vm.binotelApiKey = 'updated@example.com';
    await wrapper.vm.updateBinotelWebhookToken();
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 42,
      formData: false,
      channel: {
        provider_config: {
          provider_kind: 'binotel',
          binotel_events_webhook_token: 'saved-token',
          binotel_api_key: 'updated@example.com',
        },
      },
    });
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
    expect(
      enTe('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TITLE')
    ).toBe(true);
    expect(
      ruTe('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BEELINE_WEBHOOK_TITLE')
    ).toBe(true);
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
    const wrapper = buildWrapper({ section: 'calls' });
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
      section: 'calls',
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
      section: 'calls',
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
    const callsWrapper = buildWrapper({ section: 'calls' });
    await flushPromises();
    updateVirtualPbxChannelMock.mockClear();

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(callsWrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.LABEL'
    );
    expect(callsWrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(callsWrapper.text()).toContain(
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
    const wrapper = buildWrapper({ section: 'calls' });
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
      wrapper
        .find('[data-testid="virtual-pbx-carrier-badge"]')
        .attributes('src')
    ).toBe('/integrations/channels/badges/altel.svg');

    expect(
      wrapper
        .find('[data-testid="virtual-pbx-detected-channel-limit"]')
        .exists()
    ).toBe(true);
    await wrapper
      .find('[data-testid="virtual-pbx-apply-detected-limit"]')
      .trigger('click');
    expect(wrapper.vm.virtualPbxForm.maxChannels).toBe(2);
  });

  it('renders and saves the Visual Inbound & Outbound Call Routing Builder across Virtual PBX channels', async () => {
    const wrapper = buildWrapper({ section: 'calls' });
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
      section: 'calls',
      storeGetters: {
        'inboxes/getInboxes': [whatsappCloudInbox, whatsappPersonalInbox],
      },
    });
    await flushPromises();

    await wrapper
      .find('[data-testid="call-routing-whatsapp-followup-enabled"]')
      .setValue(true);
    expect(
      wrapper
        .find('[data-testid="call-routing-whatsapp-followup-panel"]')
        .exists()
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
    const callsWrapper = buildWrapper({
      section: 'calls',
      inbox: { ...baseInbox, provider: 'wazo' },
    });
    await flushPromises();

    expect(
      wrapper.find('[data-testid="virtual-pbx-ai-concurrency-badge"]').exists()
    ).toBe(true);
    expect(wrapper.vm.effectiveAiMaxConcurrentCalls).toBe(2);
    expect(
      callsWrapper
        .find('[data-testid="call-routing-wazo-onelink-badge"]')
        .exists()
    ).toBe(true);
    expect(
      callsWrapper
        .find('[data-testid="call-routing-authority-selector"]')
        .exists()
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
      section: 'calls',
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

const PBX_PROVIDERS = [
  'sipuni',
  'binotel',
  'asterisk_analog',
  'beeline',
  'wazo',
];

const statusFor = provider => ({
  payload: {
    ...statusPayload.payload,
    ui_config: {
      ...statusPayload.payload.ui_config,
      channel: {
        ...statusPayload.payload.ui_config.channel,
        provider_kind: provider,
      },
      connection: {
        ...statusPayload.payload.ui_config.connection,
        provider_kind: provider,
        ...(provider === 'beeline'
          ? {
              sip_domain: 'vpbx-company-test.cloudpbx.beeline.kz',
              outbound_proxy: '46.227.186.231:6050',
            }
          : {}),
      },
    },
  },
});

const CODE_BLOCKS = 'woot-code-stub, woot-code';
const INPUTS = 'woot-input-stub, woot-input';
const DEVELOPER = '[data-testid="developer-details"]';

describe('ConfigurationPage voice tabs: calls and employees vs configuration', () => {
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
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
    window.chatwootConfig = { hostURL: 'https://dev.one-link.kz' };
  });

  it('shows employees and call routing only on the calls tab', async () => {
    getVirtualPbxStatusMock.mockResolvedValue(statusFor('asterisk_analog'));
    const inbox = { ...baseInbox, provider: 'asterisk_analog' };
    const calls = buildWrapper({ inbox, section: 'calls' });
    const configuration = buildWrapper({ inbox });
    await flushPromises();

    expect(calls.find('[data-testid="virtual-pbx-add-profile"]').exists()).toBe(
      true
    );
    expect(calls.find('[data-testid="call-routing-builder"]').exists()).toBe(
      true
    );
    expect(calls.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OPERATOR_DISTRIBUTION.LABEL'
    );
    expect(
      calls.find('[data-testid="virtual-pbx-connection-host"]').exists()
    ).toBe(false);
    expect(calls.find(DEVELOPER).exists()).toBe(false);

    expect(
      configuration.find('[data-testid="virtual-pbx-add-profile"]').exists()
    ).toBe(false);
    expect(
      configuration.find('[data-testid="call-routing-builder"]').exists()
    ).toBe(false);
  });

  it('keeps the SIP server fields inside the developer block of the configuration tab', async () => {
    getVirtualPbxStatusMock.mockResolvedValue(statusFor('asterisk_analog'));
    const configuration = buildWrapper({
      inbox: { ...baseInbox, provider: 'asterisk_analog' },
    });
    await flushPromises();

    const developer = configuration.find(DEVELOPER);

    expect(developer.exists()).toBe(true);
    expect(
      developer.find('[data-testid="virtual-pbx-connection-host"]').exists()
    ).toBe(true);
    expect(developer.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.LABEL'
    );
    expect(developer.find('[data-testid="virtual-pbx-plan"]').exists()).toBe(
      true
    );
    expect(
      developer.find('[data-testid="virtual-pbx-reconcile"]').exists()
    ).toBe(true);
    expect(
      configuration.find('[data-testid="virtual-pbx-provider-kind"]').exists()
    ).toBe(true);
    expect(
      configuration
        .find('[data-testid="virtual-pbx-provider-kind"]')
        .element.closest(DEVELOPER)
    ).toBeNull();
  });

  it('keeps the webhook address and tokens of a Sipuni channel in the developer block', async () => {
    const configuration = buildWrapper({
      inbox: {
        ...baseInbox,
        provider: 'sipuni',
        provider_config: { sipuni_events_webhook_token: 'saved-token' },
      },
    });
    await flushPromises();

    const developer = configuration.find(DEVELOPER);

    expect(developer.find(CODE_BLOCKS).attributes('script')).toBe(
      'https://dev.one-link.kz/sipuni/events/saved-token'
    );
    expect(configuration.findAll(CODE_BLOCKS)).toHaveLength(
      developer.findAll(CODE_BLOCKS).length
    );
  });

  it('shows the provider and number of a Sipuni channel read only and has nothing to save', async () => {
    const configuration = buildWrapper();
    await flushPromises();

    const summary = configuration.find('[data-testid="virtual-pbx-summary"]');

    expect(summary.exists()).toBe(true);
    expect(summary.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.SIPUNI'
    );
    expect(summary.text()).toContain(virtualPbxDisplayNumber);
    expect(configuration.find('button[type="submit"]').exists()).toBe(false);
  });

  it('lets a manager save from the calls tab even for Sipuni', async () => {
    const calls = buildWrapper({ section: 'calls' });
    await flushPromises();

    expect(calls.find('button[type="submit"]').exists()).toBe(true);
  });

  it('sends exactly the same payload from the configuration tab and the calls tab', async () => {
    getVirtualPbxStatusMock.mockResolvedValue(statusFor('beeline'));
    const inbox = { ...baseInbox, provider: 'beeline' };
    const configuration = buildWrapper({ inbox });
    const calls = buildWrapper({ inbox, section: 'calls' });
    await flushPromises();

    await configuration.vm.updateVirtualPbxChannel();
    await calls.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledTimes(2);
    expect(updateVirtualPbxChannelMock.mock.calls[1]).toEqual(
      updateVirtualPbxChannelMock.mock.calls[0]
    );
  });

  it.each(PBX_PROVIDERS)(
    'lets a manager add an employee extension on the calls tab for %s',
    async provider => {
      getVirtualPbxStatusMock.mockResolvedValue({
        payload: {
          ...statusFor(provider).payload,
          ui_config: {
            ...statusFor(provider).payload.ui_config,
            employees: [],
          },
        },
      });
      const calls = buildWrapper({
        section: 'calls',
        inbox: { ...baseInbox, provider },
      });
      await flushPromises();
      updateVirtualPbxChannelMock.mockClear();

      await calls
        .find('[data-testid="virtual-pbx-add-profile"]')
        .trigger('click');
      const extensionInput = calls.find(
        'input[placeholder="INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.PLACEHOLDER"]'
      );
      expect(extensionInput.exists()).toBe(true);
      await extensionInput.setValue('777');
      calls.vm.virtualPbxForm.profiles[0].userId = 8;

      await calls.find('form').trigger('submit');
      await flushPromises();

      expect(updateVirtualPbxChannelMock).toHaveBeenCalledTimes(1);
      expect(updateVirtualPbxChannelMock.mock.calls[0][1].profiles).toEqual([
        {
          profile_kind: 'human_operator',
          user_id: 8,
          internal_extension: '777',
          enabled: true,
        },
      ]);
    }
  );
});

describe('ConfigurationPage developer blocks on other channels', () => {
  beforeEach(() => {
    storeDispatchMock.mockReset();
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
  });

  const manualCloudInbox = {
    id: 55,
    name: 'WhatsApp Cloud',
    channel_type: 'Channel::Whatsapp',
    provider: 'whatsapp_cloud',
    provider_config: { calling_enabled: false },
    callback_webhook_url: 'https://dev.one-link.kz/webhooks/whatsapp/+7000',
    members: [],
  };

  it('keeps the manual WhatsApp Cloud webhook address and API key in the developer block', () => {
    const wrapper = buildWrapper({ inbox: manualCloudInbox });
    const developer = wrapper.find(DEVELOPER);

    expect(developer.find(CODE_BLOCKS).attributes('script')).toBe(
      'https://dev.one-link.kz/webhooks/whatsapp/+7000'
    );
    expect(developer.find(INPUTS).exists()).toBe(true);
    expect(wrapper.findAll(CODE_BLOCKS)).toHaveLength(1);
    expect(wrapper.findAll(INPUTS)).toHaveLength(1);
  });

  it('shows no developer block for an embedded WhatsApp Cloud channel without errors', () => {
    const wrapper = buildWrapper({
      inbox: {
        ...manualCloudInbox,
        provider_config: { source: 'embedded_signup', calling_enabled: false },
      },
    });

    expect(wrapper.find(DEVELOPER).exists()).toBe(false);
  });

  it('moves a raw coexistence error into the developer block', () => {
    const wrapper = buildWrapper({
      inbox: {
        ...manualCloudInbox,
        provider_config: {
          source: 'embedded_signup',
          embedded_signup_flow: 'coexistence',
          coexistence_sync: {
            state: 'failed',
            last_error: 'raw provider text',
          },
        },
      },
    });

    expect(
      wrapper
        .find(DEVELOPER)
        .find('[data-testid="whatsapp-coexistence-sync-error"]')
        .text()
    ).toContain('raw provider text');
    expect(
      wrapper.find('[data-testid="whatsapp-coexistence-sync-status"]').text()
    ).not.toContain('raw provider text');
  });

  it('keeps the website widget identity validation secret in the developer block', () => {
    const wrapper = buildWrapper({
      inbox: {
        id: 12,
        name: 'Website',
        channel_type: 'Channel::WebWidget',
        hmac_token: 'secret-hmac-token',
        members: [],
      },
    });
    const toggles = wrapper.findAllComponents({
      name: 'SettingsToggleSection',
    });
    const headers = inDeveloper =>
      toggles
        .filter(
          component =>
            Boolean(component.element.closest(DEVELOPER)) === inDeveloper
        )
        .map(component => component.props('header'));

    expect(headers(true)).toEqual([
      'INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.TITLE',
      'INBOX_MGMT.SETTINGS_POPUP.IDENTITY_VALIDATION.REQUIRE_LABEL',
    ]);
    expect(headers(false)).toEqual([
      'INBOX_MGMT.SETTINGS_POPUP.ALLOWED_DOMAINS.TITLE',
      'INBOX_MGMT.SETTINGS_POPUP.ALLOW_MOBILE_WEBVIEW.LABEL',
    ]);
  });
});

const wazoStatus = ({
  remoteCommitAllowed = true,
  configurationVersion = 7,
  warnings = [],
} = {}) => {
  const base = statusFor('wazo');
  return {
    payload: {
      ...base.payload,
      warnings,
      ui_config: {
        ...base.payload.ui_config,
        configuration_version: configurationVersion,
        permissions: {
          ...base.payload.ui_config.permissions,
          remote_commit_allowed: remoteCommitAllowed,
        },
      },
    },
  };
};

const wazoInbox = { ...baseInbox, provider: 'wazo' };
const SYNC_BUTTON = '[data-testid="virtual-pbx-wazo-apply"]';

describe('ConfigurationPage Wazo sync button', () => {
  beforeEach(() => {
    alertMock.mockReset();
    getVirtualPbxStatusMock.mockReset();
    getVirtualPbxProvisioningRunsMock.mockReset();
    provisionVirtualPbxChannelMock.mockReset();
    storeDispatchMock.mockReset();
    getVirtualPbxStatusMock.mockResolvedValue(wazoStatus());
    getVirtualPbxProvisioningRunsMock.mockResolvedValue({
      payload: { provisioning_runs: [] },
    });
    provisionVirtualPbxChannelMock.mockResolvedValue({
      payload: { status: 'succeeded', remote_commit: true, errors: [] },
    });
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
    window.chatwootConfig = { hostURL: 'https://dev.one-link.kz' };
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('puts «Синхронизировать с телефонией» next to «Сохранить» on the calls tab', async () => {
    const confirmMock = vi.spyOn(window, 'confirm').mockReturnValue(true);
    const calls = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();

    const sync = calls.find(SYNC_BUTTON);
    const save = calls.find('button[type="submit"]');

    expect(sync.exists()).toBe(true);
    expect(calls.find(DEVELOPER).exists()).toBe(false);
    expect(sync.element.parentElement).toBe(save.element.parentElement);
    expect(sync.text()).toBe(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVISION_BUTTON'
    );
    expect(
      calls.find('[data-testid="virtual-pbx-wazo-sync-hint"]').exists()
    ).toBe(true);

    await sync.trigger('click');
    await flushPromises();

    expect(confirmMock).toHaveBeenCalledTimes(1);
    expect(provisionVirtualPbxChannelMock).toHaveBeenCalledWith(42, {
      remoteCommit: true,
      includeDiagnostics: false,
    });
  });

  it('keeps the button outside the collapsed developer block on the configuration tab too', async () => {
    const configuration = buildWrapper({ inbox: wazoInbox });
    await flushPromises();

    const sync = configuration.find(SYNC_BUTTON);

    expect(sync.exists()).toBe(true);
    expect(sync.element.closest(DEVELOPER)).toBeNull();
    expect(configuration.findAll(SYNC_BUTTON)).toHaveLength(1);
  });

  it.each(['sipuni', 'binotel', 'asterisk_analog', 'beeline'])(
    'does not offer Wazo sync for %s',
    async provider => {
      getVirtualPbxStatusMock.mockResolvedValue(statusFor(provider));
      const calls = buildWrapper({
        inbox: { ...baseInbox, provider },
        section: 'calls',
      });
      await flushPromises();

      expect(calls.find(SYNC_BUTTON).exists()).toBe(false);
      expect(
        calls.find('[data-testid="virtual-pbx-wazo-sync-hint"]').exists()
      ).toBe(false);
    }
  );
});

describe('ConfigurationPage unsaved voice edits', () => {
  beforeEach(() => {
    alertMock.mockReset();
    getVirtualPbxStatusMock.mockReset();
    getVirtualPbxProvisioningRunsMock.mockReset();
    provisionVirtualPbxChannelMock.mockReset();
    reconcileVirtualPbxChannelMock.mockReset();
    updateVirtualPbxChannelMock.mockReset();
    storeDispatchMock.mockReset();
    getVirtualPbxStatusMock.mockResolvedValue(wazoStatus());
    getVirtualPbxProvisioningRunsMock.mockResolvedValue({
      payload: { provisioning_runs: [] },
    });
    provisionVirtualPbxChannelMock.mockResolvedValue({
      payload: { status: 'succeeded', remote_commit: true, errors: [] },
    });
    reconcileVirtualPbxChannelMock.mockResolvedValue({
      payload: { status: 'in_sync', drift: [] },
    });
    updateVirtualPbxChannelMock.mockResolvedValue({ payload: { errors: [] } });
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
    window.chatwootConfig = { hostURL: 'https://dev.one-link.kz' };
    vi.spyOn(window, 'confirm').mockReturnValue(true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const addUnsavedEmployee = async wrapper => {
    await wrapper
      .find('[data-testid="virtual-pbx-add-profile"]')
      .trigger('click');
    wrapper.vm.virtualPbxForm.profiles[1].internalExtension = '105';
  };

  const holdReconcile = () => {
    let finish;
    reconcileVirtualPbxChannelMock.mockReturnValue(
      new Promise(resolve => {
        finish = () => resolve({ payload: { status: 'in_sync', drift: [] } });
      })
    );
    return () => finish();
  };

  it('is clean after loading and after a save, dirty after an edit', async () => {
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    expect(wrapper.vm.hasUnsavedVirtualPbxChanges).toBe(false);

    wrapper.vm.callRoutingForm.inbound.ring_timeout_seconds = 45;
    expect(wrapper.vm.hasUnsavedVirtualPbxChanges).toBe(true);

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    expect(updateVirtualPbxChannelMock).toHaveBeenCalledTimes(1);
    expect(wrapper.vm.hasUnsavedVirtualPbxChanges).toBe(false);
  });

  it('does not run the PBX check over employees that are not saved yet', async () => {
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    await addUnsavedEmployee(wrapper);
    getVirtualPbxStatusMock.mockClear();
    alertMock.mockClear();

    await wrapper.vm.reconcileVirtualPbxChannel();
    await flushPromises();

    expect(reconcileVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(getVirtualPbxStatusMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.SAVE_FIRST'
    );
    expect(wrapper.vm.virtualPbxForm.profiles).toHaveLength(2);
    expect(wrapper.vm.virtualPbxForm.profiles[1].internalExtension).toBe('105');
  });

  it('does not sync the PBX while employees are not saved, and does not even ask to confirm', async () => {
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    await addUnsavedEmployee(wrapper);
    alertMock.mockClear();

    await wrapper.find(SYNC_BUTTON).trigger('click');
    await flushPromises();

    expect(window.confirm).not.toHaveBeenCalled();
    expect(provisionVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.SAVE_FIRST'
    );
    expect(wrapper.vm.virtualPbxForm.profiles).toHaveLength(2);
  });

  it('shares the check between tabs: edits made on the calls tab block the button of the configuration tab', async () => {
    // Settings.vue renders both tabs with one component instance, so one
    // wrapper stands for "edit on one tab, click on the other".
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    await addUnsavedEmployee(wrapper);
    await wrapper.setProps({ section: 'configuration' });
    alertMock.mockClear();

    await wrapper
      .find('[data-testid="virtual-pbx-reconcile"]')
      .trigger('click');
    await flushPromises();

    expect(reconcileVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.SAVE_FIRST'
    );
    await wrapper.setProps({ section: 'calls' });
    expect(wrapper.vm.virtualPbxForm.profiles).toHaveLength(2);
  });

  it('works again once the edits are saved', async () => {
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    wrapper.vm.callRoutingForm.inbound.ring_timeout_seconds = 45;

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();
    await wrapper.vm.reconcileVirtualPbxChannel();
    await flushPromises();

    expect(reconcileVirtualPbxChannelMock).toHaveBeenCalledTimes(1);
  });

  it('refreshes the status but keeps edits made while the check is running', async () => {
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    const finishCheck = holdReconcile();
    getVirtualPbxStatusMock.mockResolvedValue(
      wazoStatus({ configurationVersion: 8 })
    );

    const check = wrapper.vm.reconcileVirtualPbxChannel();
    await flushPromises();
    await addUnsavedEmployee(wrapper);
    finishCheck();
    await check;
    await flushPromises();

    expect(wrapper.vm.virtualPbxConfig.configuration_version).toBe(8);
    expect(wrapper.vm.virtualPbxForm.profiles).toHaveLength(2);
    expect(wrapper.vm.virtualPbxForm.profiles[1].internalExtension).toBe('105');
    expect(wrapper.vm.hasUnsavedVirtualPbxChanges).toBe(true);
  });

  it('sends the refreshed configuration version when the kept edits are saved', async () => {
    const wrapper = buildWrapper({ inbox: wazoInbox, section: 'calls' });
    await flushPromises();
    const finishCheck = holdReconcile();
    getVirtualPbxStatusMock.mockResolvedValue(
      wazoStatus({ configurationVersion: 9 })
    );
    const check = wrapper.vm.reconcileVirtualPbxChannel();
    await flushPromises();
    wrapper.vm.virtualPbxForm.profiles.push({
      ...wrapper.vm.emptyVirtualPbxProfile(),
      userId: 8,
      internalExtension: '105',
    });
    finishCheck();
    await check;
    await flushPromises();

    await wrapper.vm.updateVirtualPbxChannel();
    await flushPromises();

    const payload = updateVirtualPbxChannelMock.mock.calls[0][1];
    expect(payload.expected_configuration_version).toBe(9);
    expect(payload.profiles.map(profile => profile.internal_extension)).toEqual(
      ['100', '105']
    );
  });
});

describe('ConfigurationPage PBX warnings', () => {
  const rawMessage =
    'Display phone and technical ingress number are intentionally different';
  const warnings = [
    { code: 'phone_split_configured', severity: 'info', message: rawMessage },
    { code: 'future_code', severity: 'warning', message: 'Something new' },
  ];

  beforeEach(() => {
    alertMock.mockReset();
    getVirtualPbxStatusMock.mockReset();
    getVirtualPbxProvisioningRunsMock.mockReset();
    storeDispatchMock.mockReset();
    getVirtualPbxStatusMock.mockResolvedValue({
      payload: { ...statusPayload.payload, warnings },
    });
    getVirtualPbxProvisioningRunsMock.mockResolvedValue({
      payload: { provisioning_runs: [] },
    });
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
    window.chatwootConfig = { hostURL: 'https://dev.one-link.kz' };
  });

  it('keeps warnings off the calls tab and inside the developer block of the configuration tab', async () => {
    const calls = buildWrapper({ section: 'calls', te: ruTe });
    const configuration = buildWrapper({ te: ruTe });
    await flushPromises();

    expect(calls.find('[data-testid="virtual-pbx-warnings"]').exists()).toBe(
      false
    );
    expect(calls.text()).not.toContain(rawMessage);
    expect(calls.text()).not.toContain('WARNINGS_TITLE');

    const box = configuration.find('[data-testid="virtual-pbx-warnings"]');
    expect(box.exists()).toBe(true);
    expect(box.element.closest(DEVELOPER)).not.toBeNull();
    expect(box.text()).toContain('WARNINGS_TITLE');
  });

  it('shows a known warning by its code and keeps the server text for an unknown code', async () => {
    const configuration = buildWrapper({ te: ruTe });
    await flushPromises();

    const items = configuration
      .find('[data-testid="virtual-pbx-warnings"]')
      .findAll('li')
      .map(item => item.text());

    expect(items).toEqual([
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.WARNINGS.PHONE_SPLIT_CONFIGURED',
      'Something new',
    ]);
  });
});

describe('ConfigurationPage Twilio and LINE panels', () => {
  beforeEach(() => {
    storeDispatchMock.mockReset();
    storeDispatchMock.mockResolvedValue({ data: { payload: [] } });
    alertMock.mockReset();
  });

  const twilioInbox = medium => ({
    id: 61,
    name: 'Twilio',
    channel_type: 'Channel::TwilioSms',
    medium,
    callback_webhook_url: 'https://dev.one-link.kz/twilio/callback',
    provider_config: {},
    members: [],
  });

  it('shows the Twilio callback address in the developer block', () => {
    const wrapper = buildWrapper({ inbox: twilioInbox('whatsapp') });
    const developer = wrapper.find(DEVELOPER);

    expect(developer.find(CODE_BLOCKS).attributes('script')).toBe(
      'https://dev.one-link.kz/twilio/callback'
    );
    expect(wrapper.findAll(CODE_BLOCKS)).toHaveLength(1);
    expect(developer.text()).toContain(
      'INBOX_MGMT.ADD.TWILIO.API_CALLBACK.TITLE'
    );
  });

  it('syncs the templates of Twilio WhatsApp outside the developer block', async () => {
    const wrapper = buildWrapper({ inbox: twilioInbox('whatsapp') });
    const button = wrapper
      .findAll('button')
      .find(item =>
        item
          .text()
          .includes('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_BUTTON')
      );

    expect(wrapper.find(DEVELOPER).findAll('button')).toHaveLength(0);
    expect(button).toBeTruthy();

    await button.trigger('click');
    await flushPromises();

    expect(storeDispatchMock).toHaveBeenCalledWith('inboxes/syncTemplates', 61);
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUCCESS'
    );
  });

  it('offers no template sync for Twilio SMS', () => {
    const wrapper = buildWrapper({ inbox: twilioInbox('sms') });

    expect(wrapper.findAll('button')).toHaveLength(0);
    expect(wrapper.find(DEVELOPER).find(CODE_BLOCKS).exists()).toBe(true);
  });

  it('shows the LINE callback address in the developer block', () => {
    const wrapper = buildWrapper({
      inbox: {
        id: 62,
        name: 'LINE',
        channel_type: 'Channel::Line',
        callback_webhook_url: 'https://dev.one-link.kz/line/callback',
        members: [],
      },
    });

    expect(
      wrapper.find(DEVELOPER).find(CODE_BLOCKS).attributes('script')
    ).toBe('https://dev.one-link.kz/line/callback');
    expect(wrapper.findAll(CODE_BLOCKS)).toHaveLength(1);
  });
});

describe('ConfigurationPage texts', () => {
  const pick = (tree, path) =>
    path.split('.').reduce((node, part) => node?.[part], tree);
  const VOICE = 'INBOX_MGMT.ADD.VOICE';
  const POPUP = 'INBOX_MGMT.SETTINGS_POPUP';

  it('names the calls section like the tab, in every language', () => {
    [ruInboxMgmt, enInboxMgmt, kkInboxMgmt].forEach(locale => {
      expect(pick(locale, 'INBOX_MGMT.EDIT.VOICE_CALLS.CALLS_TITLE')).toBe(
        pick(locale, 'INBOX_MGMT.TABS.VOICE_CALLS')
      );
    });
    expect(pick(ruInboxMgmt, 'INBOX_MGMT.TABS.VOICE_CALLS')).toBe(
      'Звонки и сотрудники'
    );
  });

  it('describes the technical block without promising fields that Sipuni does not have', () => {
    const hint = pick(ruInboxMgmt, 'INBOX_MGMT.EDIT.VOICE_CALLS.CONFIG_HINT');

    expect(hint).toContain('Для разработчика');
    expect(hint).not.toMatch(/Параметры подключения|порт|логин/i);
  });

  it('has no English words left in the voice developer block', () => {
    [
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_TITLE`,
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_SUBTITLE`,
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_EMPTY`,
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_TOKEN`,
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_TOKEN_PLACEHOLDER`,
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_GENERATE`,
      `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_SAVE`,
      `${VOICE}.CONFIGURATION.BINOTEL_WEBHOOK_TOKEN`,
      `${VOICE}.CONFIGURATION.BINOTEL_WEBHOOK_GENERATE`,
      `${VOICE}.CONFIGURATION.BEELINE_WEBHOOK_TOKEN`,
      `${VOICE}.CONFIGURATION.BEELINE_WEBHOOK_GENERATE`,
      `${VOICE}.VIRTUAL_PBX.RECONCILE_BUTTON`,
      `${VOICE}.VIRTUAL_PBX.PROVISION_SUCCESS`,
      `${VOICE}.VIRTUAL_PBX.PROVISION_BLOCKED`,
    ].forEach(path => {
      expect(pick(ruInboxMgmt, path), path).not.toMatch(
        /webhook|token|remote|provisioning/
      );
    });
    expect(
      pick(ruInboxMgmt, `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_TITLE`)
    ).toBe('Вебхук Sipuni');
    expect(
      pick(ruInboxMgmt, `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_TOKEN`)
    ).toBe('Токен вебхука');
    expect(
      pick(ruInboxMgmt, `${VOICE}.CONFIGURATION.SIPUNI_WEBHOOK_GENERATE`)
    ).toBe('Сгенерировать токен');
    expect(pick(ruInboxMgmt, `${VOICE}.VIRTUAL_PBX.RECONCILE_BUTTON`)).toBe(
      'Проверить состояние в АТС'
    );
  });

  it('uses «SIP-логин», «SIP-пароль» and «ИИ-агент» on the employees form', () => {
    const base = `${VOICE}.VIRTUAL_PBX`;

    expect(pick(ruInboxMgmt, `${base}.EMPLOYEE_SIP_USERNAME.LABEL`)).toBe(
      'SIP-логин'
    );
    expect(pick(ruInboxMgmt, `${base}.EMPLOYEE_SIP_PASSWORD.LABEL`)).toBe(
      'SIP-пароль'
    );
    expect(
      pick(ruInboxMgmt, `${base}.EMPLOYEE_PROFILES.VOICE_AGENT_LABEL`)
    ).toBe('ИИ-агент');
    expect(pick(ruInboxMgmt, `${base}.EMPLOYEE_PROFILES.HINT`)).not.toMatch(
      /диагностик/i
    );
    ['EMPLOYEE_SIP_USERNAME', 'EMPLOYEE_SIP_PASSWORD'].forEach(key => {
      expect(JSON.stringify(pick(ruInboxMgmt, `${base}.${key}`))).not.toMatch(
        /username|password/i
      );
    });
  });

  it('writes WhatsApp calling in Russian and tells the templates title from its button', () => {
    expect(pick(ruInboxMgmt, `${POPUP}.WHATSAPP_CALLING_TITLE`)).toBe(
      'Звонки в WhatsApp'
    );
    expect(pick(ruInboxMgmt, `${POPUP}.WHATSAPP_CALLING_LABEL`)).toBe(
      'Включить звонки в WhatsApp'
    );
    expect(pick(ruInboxMgmt, `${POPUP}.WHATSAPP_AI_VOICE_TITLE`)).toBe(
      'Голосовой ИИ-агент'
    );
    expect(pick(ruInboxMgmt, `${POPUP}.WHATSAPP_AI_VOICE_LABEL`)).toBe(
      'Включить автоответ голосового ИИ-агента'
    );
    expect(pick(ruInboxMgmt, `${POPUP}.WHATSAPP_AI_VOICE_SUBHEADER`)).toMatch(
      /ИИ-агенту.*ожидающих диалогах/
    );
    [ruInboxMgmt, enInboxMgmt].forEach(locale => {
      expect(pick(locale, `${POPUP}.WHATSAPP_TEMPLATES_SYNC_TITLE`)).not.toBe(
        pick(locale, `${POPUP}.WHATSAPP_TEMPLATES_SYNC_BUTTON`)
      );
    });
    expect(pick(ruInboxMgmt, `${POPUP}.WHATSAPP_TEMPLATES_SYNC_TITLE`)).toBe(
      'Шаблоны сообщений'
    );
  });

  it('has every new key in Russian, English and Kazakh', () => {
    const base = `${VOICE}.VIRTUAL_PBX`;
    const warningPaths = Object.keys(pick(ruInboxMgmt, `${base}.WARNINGS`)).map(
      key => `${base}.WARNINGS.${key}`
    );

    expect(warningPaths.length).toBeGreaterThan(10);
    [`${base}.SAVE_FIRST`, `${base}.WAZO_SYNC_HINT`, ...warningPaths].forEach(
      path => {
        [ruInboxMgmt, enInboxMgmt, kkInboxMgmt].forEach(locale => {
          expect(typeof pick(locale, path), path).toBe('string');
        });
      }
    );
    warningPaths.forEach(path => {
      expect(pick(ruInboxMgmt, path), path).toMatch(/[А-Яа-яЁё]/);
      expect(pick(kkInboxMgmt, path), path).toMatch(/[А-Яа-яЁё]/);
    });
  });
});
