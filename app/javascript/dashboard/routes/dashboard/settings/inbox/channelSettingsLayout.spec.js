import { describe, expect, it, vi } from 'vitest';
import { flushPromises, mount, shallowMount } from '@vue/test-utils';

import DeveloperDetails from './components/DeveloperDetails.vue';
import Settings from './Settings.vue';

// The inside of a channel is written for a non-technical business owner:
// technical details sit in a «Для разработчика» block that starts closed, and
// a voice channel has its own «Звонки и сотрудники» tab.

const tabsContext = (overrides = {}) => ({
  $t: key => key,
  inbox: {},
  isAVoiceChannel: false,
  isAWebWidgetInbox: false,
  isAPIInbox: false,
  isAWhatsAppWebInbox: false,
  isAnEmailChannel: false,
  shouldShowWhatsAppConfiguration: false,
  ...overrides,
});

const tabKeys = overrides =>
  Settings.computed.tabs.call(tabsContext(overrides)).map(tab => tab.key);

describe('DeveloperDetails', () => {
  const mountBlock = () =>
    mount(DeveloperDetails, {
      slots: { default: '<p data-testid="technical">instance-42</p>' },
    });

  it('is collapsed by default and keeps its content out of the page', () => {
    const wrapper = mountBlock();

    expect(wrapper.find('[data-testid="developer-details"]').exists()).toBe(
      true
    );
    expect(wrapper.find('button').text()).toBe('For developers');
    expect(wrapper.find('button').attributes('aria-expanded')).toBe('false');
    expect(wrapper.find('[data-testid="technical"]').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('instance-42');
  });

  it('opens on click and never submits a surrounding form', async () => {
    const wrapper = mountBlock();

    await wrapper.find('button').trigger('click');

    expect(wrapper.find('button').attributes('type')).toBe('button');
    expect(wrapper.find('button').attributes('aria-expanded')).toBe('true');
    expect(wrapper.find('[data-testid="technical"]').text()).toBe(
      'instance-42'
    );
  });
});

describe('Channel settings tabs for voice inboxes', () => {
  it.each(['sipuni', 'binotel', 'asterisk_analog', 'beeline', 'wazo'])(
    'has the «Звонки и сотрудники» tab for a %s voice inbox',
    provider => {
      const tabs = Settings.computed.tabs.call(
        tabsContext({ isAVoiceChannel: true, inbox: { provider } })
      );

      expect(tabs.map(tab => tab.key)).toEqual([
        'inbox-settings',
        'voice-calls',
        'configuration',
      ]);
      expect(tabs[1].name).toBe('INBOX_MGMT.TABS.VOICE_CALLS');
    }
  );

  it('has no calls tab for a Twilio voice inbox or for other channels', () => {
    expect(
      tabKeys({ isAVoiceChannel: true, inbox: { provider: 'twilio' } })
    ).toEqual(['inbox-settings', 'configuration']);
    expect(tabKeys({ isAWebWidgetInbox: true })).not.toContain('voice-calls');
    expect(tabKeys({ shouldShowWhatsAppConfiguration: true })).not.toContain(
      'voice-calls'
    );
  });

  it('opens the configuration page in its calls section on that tab', () => {
    const section = tab =>
      Settings.computed.configurationSection.call({ selectedTabKey: tab });

    expect(section('voice-calls')).toBe('calls');
    expect(section('configuration')).toBe('configuration');
    expect(section('inbox-settings')).toBe('');
  });

  it('no longer offers tabs for removed channel types', () => {
    const all = [
      tabKeys({ isAVoiceChannel: true, inbox: { provider: 'sipuni' } }),
      tabKeys({ isAWebWidgetInbox: true }),
      tabKeys({ isAPIInbox: true }),
      tabKeys({ isAnEmailChannel: true }),
      tabKeys({ shouldShowWhatsAppConfiguration: true }),
    ].flat();

    expect(all).not.toContain('csat');
    expect(all).not.toContain('bot-configuration');
    expect(
      Settings.computed.tabs
        .call(tabsContext({ isATwilioChannel: true }))
        .map(tab => tab.key)
    ).toEqual(['inbox-settings']);
    expect(
      Settings.computed.tabs
        .call(tabsContext({ isALineChannel: true }))
        .map(tab => tab.key)
    ).toEqual(['inbox-settings']);
  });
});

describe('Channel settings header status', () => {
  it('shows the label and description of phone registration from the status helper keys', () => {
    const context = {
      $t: key => `t:${key}`,
      inboxHealthStatus: {
        id: 'phone_registration_required',
        labelKey: 'INBOX_MGMT.HEALTH_STATUS.PHONE_REGISTRATION_REQUIRED',
        descriptionKey:
          'INBOX_MGMT.HEALTH_STATUS.PHONE_REGISTRATION_REQUIRED_DESCRIPTION',
        detail: '',
      },
    };

    expect(Settings.computed.inboxHealthStatusLabel.call(context)).toBe(
      't:INBOX_MGMT.HEALTH_STATUS.PHONE_REGISTRATION_REQUIRED'
    );
    expect(Settings.computed.inboxHealthStatusDescription.call(context)).toBe(
      't:INBOX_MGMT.HEALTH_STATUS.PHONE_REGISTRATION_REQUIRED_DESCRIPTION'
    );
  });

  it('prefers the sanitized provider detail over the generic description', () => {
    expect(
      Settings.computed.inboxHealthStatusDescription.call({
        $t: key => key,
        inboxHealthStatus: {
          id: 'disconnected',
          labelKey: 'a',
          descriptionKey: 'b',
          detail: 'Session was closed',
        },
      })
    ).toBe('Session was closed');
  });

  it('shows nothing when there is no status', () => {
    expect(
      Settings.computed.inboxHealthStatusLabel.call({
        $t: key => key,
        inboxHealthStatus: null,
      })
    ).toBe('');
    expect(
      Settings.computed.inboxHealthStatusDescription.call({
        $t: key => key,
        inboxHealthStatus: null,
      })
    ).toBe('');
  });
});

describe('Channel settings save payload', () => {
  const payloadFor = overrides =>
    Settings.methods.buildUpdatePayload.call({
      currentInboxId: 7,
      selectedInboxName: ' Clinic ',
      inbox: { widget_color: '#1f93ff' },
      emailCollectEnabled: false,
      allowMessagesAfterResolved: true,
      senderNameType: 'friendly',
      businessName: '',
      channelWebsiteUrl: 'https://example.test',
      channelWelcomeTitle: 'Hi',
      channelWelcomeTagline: '',
      selectedFeatureFlags: ['attachments'],
      replyTime: '',
      continuityViaEmail: true,
      webhookUrl: 'https://hook.test',
      whatsappWebConversationPending: false,
      whatsappWebHistoryLookbackDays: 0,
      whatsappWebIgnoreJids: '',
      whatsappWebSignMessages: false,
      whatsappWebSignDelimiter: '\\n',
      whatsappWebImportContacts: true,
      whatsappWebImportMessages: true,
      whatsappWebSyncLabels: true,
      whatsappWebSyncGroups: false,
      normalizedWhatsappWebHistoryLookbackDays: () => 0,
      normalizedWhatsappWebIgnoreJids: () => [],
      isAWebWidgetInbox: false,
      isAnEmailChannel: false,
      isAPIInbox: false,
      isAWhatsAppWebInbox: false,
      ...overrides,
    });

  it('never re-sends the greeting or the single-conversation lock', () => {
    [
      {},
      { isAWebWidgetInbox: true },
      { isAWhatsAppWebInbox: true, isAPIInbox: true },
      { isAnEmailChannel: true },
    ].forEach(overrides => {
      const payload = payloadFor(overrides);

      expect(payload).not.toHaveProperty('greeting_enabled');
      expect(payload).not.toHaveProperty('greeting_message');
      expect(payload).not.toHaveProperty('lock_to_single_conversation');
    });
  });

  it('sends only the name for a channel without editable options', () => {
    expect(payloadFor({})).toEqual({ id: 7, name: 'Clinic' });
  });

  it('sends the widget options only for a website widget', () => {
    const widget = payloadFor({ isAWebWidgetInbox: true });

    expect(widget).toMatchObject({
      id: 7,
      name: 'Clinic',
      enable_email_collect: false,
      allow_messages_after_resolved: true,
      sender_name_type: 'friendly',
      business_name: null,
      channel: {
        widget_color: '#1f93ff',
        website_url: 'https://example.test',
        welcome_title: 'Hi',
        welcome_tagline: '',
        selectedFeatureFlags: ['attachments'],
        reply_time: 'in_a_few_minutes',
        continuity_via_email: true,
      },
    });
    expect(payloadFor({}).channel).toBeUndefined();
  });

  it('sends the sender name only for widget and email channels', () => {
    expect(payloadFor({ isAnEmailChannel: true })).toEqual({
      id: 7,
      name: 'Clinic',
      sender_name_type: 'friendly',
      business_name: null,
    });
  });

  it('sends the webhook address only for an API channel', () => {
    expect(payloadFor({ isAPIInbox: true }).channel).toEqual({
      webhook_url: 'https://hook.test',
    });
    expect(
      payloadFor({ isAPIInbox: true, isAWhatsAppWebInbox: true }).channel
    ).not.toHaveProperty('webhook_url');
  });

  it('sends the unchanged WhatsApp Web options', () => {
    expect(payloadFor({ isAWhatsAppWebInbox: true }).channel).toEqual({
      conversation_pending: false,
      history_lookback_days: 0,
      ignore_jids: [],
      sign_messages: false,
      sign_delimiter: '\\n',
      import_contacts: true,
      import_messages: true,
      sync_labels: true,
      sync_groups: false,
    });
  });
});

const ACCOUNT_ID = 1;

const buildSettings = inbox =>
  shallowMount(Settings, {
    global: {
      mocks: {
        $store: {
          getters: {
            'inboxes/getUIFlags': { isFetching: false, isUpdating: false },
            'inboxes/getInbox': () => inbox,
            'inboxes/getInstagramInboxByInstagramId': () => undefined,
          },
          dispatch: vi.fn().mockResolvedValue({}),
        },
        $route: { params: { accountId: ACCOUNT_ID, inboxId: inbox.id } },
        $router: { resolve: () => ({ href: '/' }), replace: vi.fn() },
      },
      directives: { 'on-clickaway': {} },
      stubs: {
        'woot-tabs': true,
        'woot-tabs-item': true,
        'woot-input': true,
        'woot-code': true,
        'woot-confirm-delete-modal': true,
        SettingIntroBanner: { template: '<div><slot /></div>' },
        SettingsAccordion: { template: '<div><slot /></div>' },
        SettingsFieldSection: { template: '<div><slot /></div>' },
        ConnectionStatusBadge: false,
        DeveloperDetails: false,
        Accordion: false,
      },
    },
  });

const developerText = wrapper =>
  wrapper.find('[data-testid="developer-details"]').text();

describe('WhatsApp Web settings', () => {
  const inbox = {
    id: 5,
    account_id: ACCOUNT_ID,
    name: 'Clinic WhatsApp',
    channel_type: 'Channel::WhatsappWeb',
    phone_number: '+77001234567',
    additional_attributes: {
      evolution: {
        status: 'connected',
        connection_state: 'open',
        number: '+77001234567',
        instance_name: 'onelink-instance-42',
        last_error: '',
        service_user: { email: 'service-user@onelink.test' },
      },
    },
  };

  it('shows one status next to the actions and keeps technical data closed', async () => {
    const wrapper = buildSettings(inbox);
    await flushPromises();

    const statuses = wrapper.findAll('[data-testid="connection-status"]');
    expect(statuses).toHaveLength(1);
    expect(statuses[0].attributes('data-status')).toBe('connected');
    expect(
      wrapper
        .find('[data-testid="whatsapp-web-connection"]')
        .find('[data-testid="connection-status"]')
        .exists()
    ).toBe(true);
    expect(wrapper.find('[data-test-id="inbox-health-status"]').exists()).toBe(
      false
    );

    expect(wrapper.text()).toContain('+77001234567');
    expect(wrapper.find('[data-testid="developer-details"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).not.toContain('onelink-instance-42');
    expect(wrapper.text()).not.toContain('service-user@onelink.test');

    await wrapper
      .find('[data-testid="developer-details"] button')
      .trigger('click');

    expect(developerText(wrapper)).toContain('onelink-instance-42');
    expect(developerText(wrapper)).toContain('service-user@onelink.test');
    wrapper.unmount();
  });

  it('shows no connection when the session is closed', async () => {
    const wrapper = buildSettings({
      ...inbox,
      additional_attributes: {
        evolution: {
          ...inbox.additional_attributes.evolution,
          status: 'close',
        },
      },
    });
    await flushPromises();

    expect(
      wrapper
        .find('[data-testid="connection-status"]')
        .attributes('data-status')
    ).toBe('disconnected');
    wrapper.unmount();
  });
});

describe('Telegram Personal settings', () => {
  const inbox = {
    id: 6,
    account_id: ACCOUNT_ID,
    name: 'Telegram clinic',
    channel_type: 'Channel::TelegramPersonal',
    phone_number: '+77009876543',
    lifecycle_state: 'connected',
    connection_state: 'connected',
    last_error: '',
    runtime_state: { ignored_chat_ids: ['6002671687'], sync_groups: false },
  };

  it('shows one status next to the actions and keeps technical data closed', async () => {
    const wrapper = buildSettings(inbox);
    await flushPromises();

    const statuses = wrapper.findAll('[data-testid="connection-status"]');
    expect(statuses).toHaveLength(1);
    expect(statuses[0].attributes('data-status')).toBe('connected');
    expect(wrapper.find('[data-test-id="inbox-health-status"]').exists()).toBe(
      false
    );
    expect(wrapper.text()).toContain('+77009876543');
    expect(
      wrapper
        .find('[data-testid="telegram-personal-sync-groups-checkbox"]')
        .exists()
    ).toBe(true);

    expect(wrapper.find('[data-testid="developer-details"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).not.toContain('6002671687');

    await wrapper
      .find('[data-testid="developer-details"] button')
      .trigger('click');

    expect(developerText(wrapper)).toContain('6002671687');
    wrapper.unmount();
  });
});
