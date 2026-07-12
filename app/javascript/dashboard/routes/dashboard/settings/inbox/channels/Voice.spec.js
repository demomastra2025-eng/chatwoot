import { flushPromises, mount } from '@vue/test-utils';

import Voice from './Voice.vue';

const dispatchMock = vi.hoisted(() => vi.fn());
const routeMock = vi.hoisted(() => ({
  name: 'settings_inboxes_page_channel',
  params: { accountId: 530 },
  query: { provider: 'sipuni' },
}));
const routerReplaceMock = vi.hoisted(() => vi.fn());
const routerPushMock = vi.hoisted(() => vi.fn());
const createVirtualPbxChannelMock = vi.hoisted(() => vi.fn());
const alertMock = vi.hoisted(() => vi.fn());
const agentListMock = vi.hoisted(() => []);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => routeMock,
  useRouter: () => ({
    push: routerPushMock,
    replace: routerReplaceMock,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
  }),
  useMapGetter: getter => ({
    value:
      getter === 'inboxes/getUIFlags' ? { isCreating: false } : agentListMock,
  }),
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    createVirtualPbxChannel: createVirtualPbxChannelMock,
  },
}));

const buildWrapper = () =>
  mount(Voice, {
    global: {
      stubs: {
        PageHeader: true,
        ChannelSelector: {
          name: 'ChannelSelector',
          props: ['title', 'description', 'icon', 'imageUrl'],
          template:
            '<button type="button" @click="$emit(\'click\')">{{ title }}</button>',
        },
        Select: true,
        TagInput: true,
        NextButton: {
          props: ['disabled', 'label'],
          template:
            '<button type="submit" :disabled="disabled">{{ label }}</button>',
        },
      },
    },
  });

describe('Voice channel setup', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    routerReplaceMock.mockReset();
    routerPushMock.mockReset();
    createVirtualPbxChannelMock.mockReset();
    alertMock.mockReset();
    agentListMock.splice(0);
    dispatchMock.mockResolvedValue({ id: 101 });
    routeMock.query = { provider: 'kazakhstan' };
  });

  it('renders direct Sipuni as a Virtual PBX setup form', () => {
    routeMock.query = { provider: 'sipuni' };
    const wrapper = buildWrapper();

    expect(wrapper.find('form').exists()).toBe(true);
    expect(wrapper.text()).not.toContain('INBOX_MGMT.ADD.VOICE.SIPUNI');
  });

  it('lists Asterisk analog as a separate provider card', () => {
    routeMock.query = {};
    const wrapper = buildWrapper();

    expect(
      wrapper.vm.availableProviders.map(provider => provider.key)
    ).toContain('asterisk_analog');

    wrapper.vm.selectProvider('asterisk_analog');

    expect(wrapper.vm.kazakhstanState.providerKind).toBe('asterisk_analog');
    expect(routerPushMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_page_channel',
      params: { accountId: 530 },
      query: { provider: 'asterisk_analog' },
    });
  });

  it('passes badge images to local voice provider cards', () => {
    routeMock.query = {};
    const wrapper = buildWrapper();
    const cards = wrapper.findAllComponents({ name: 'ChannelSelector' });
    const imageUrlByTitle = new Map(
      cards.map(card => [card.props('title'), card.props('imageUrl')])
    );

    expect(imageUrlByTitle.get('INBOX_MGMT.ADD.VOICE.PROVIDERS.SIPUNI')).toBe(
      '/integrations/channels/badges/sipuni.png'
    );
    expect(imageUrlByTitle.get('INBOX_MGMT.ADD.VOICE.PROVIDERS.BINOTEL')).toBe(
      '/integrations/channels/badges/binotel.png'
    );
    expect(
      imageUrlByTitle.get('INBOX_MGMT.ADD.VOICE.PROVIDERS.ASTERISK_ANALOG')
    ).toBe('/integrations/channels/badges/Asterisk.png');
  });

  it('creates a Virtual PBX Sipuni channel without employee profiles', async () => {
    routeMock.query = { provider: 'sipuni' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { ui_config: { inbox_id: 202 }, errors: [] },
    });
    const wrapper = buildWrapper();
    const inputs = wrapper.findAll('input');

    await inputs[0].setValue('Virtual PBX');
    await inputs[1].setValue('+1 555 123 4567');
    await inputs[2].setValue('sip.provider.local');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createVirtualPbxChannelMock).toHaveBeenCalledWith(
      expect.not.objectContaining({ profiles: expect.any(Array) }),
      { dryRun: false, remoteCommit: false }
    );
    const [payload, options] = createVirtualPbxChannelMock.mock.calls[0];
    expect(options).toEqual({ dryRun: false, remoteCommit: false });
    expect(payload).toMatchObject({
      provider_kind: 'sipuni',
      channel_name: 'Virtual PBX',
      connection: {
        host: 'sip.provider.local',
      },
      routing: {
        mode: 'operator',
        fallback_mode: 'reject',
        operator_distribution_mode: 'broadcast',
      },
      metadata: {
        source: 'virtual_pbx_ui',
      },
    });
    expect(payload.provider_account_number).toBe(payload.display_phone_number);
    expect(payload.ingress_number).toBe(payload.display_phone_number);
    expect(payload.connection).not.toHaveProperty('username');
    expect(payload.connection).not.toHaveProperty('password');
    expect(payload.routing).not.toHaveProperty('operator_agent_aor');
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_add_agents',
      params: {
        accountId: 530,
        inbox_id: 202,
      },
      query: { provider: 'sipuni' },
    });
  });

  it('creates a direct Binotel Virtual PBX channel as a local native provider', async () => {
    routeMock.query = { provider: 'binotel' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { ui_config: { inbox_id: 4769 }, errors: [] },
    });
    const wrapper = buildWrapper();
    const inputs = wrapper.findAll('input');

    await inputs[0].setValue('Binotel');
    await inputs[1].setValue('+7 700 078 1755');
    await inputs[2].setValue('sip53.binotel.com');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    const [payload, options] = createVirtualPbxChannelMock.mock.calls[0];
    expect(options).toEqual({ dryRun: false, remoteCommit: false });
    expect(payload).toMatchObject({
      provider_kind: 'binotel',
      channel_name: 'Binotel',
      connection: {
        host: 'sip53.binotel.com',
      },
      routing: {
        mode: 'operator',
        fallback_mode: 'reject',
        operator_distribution_mode: 'broadcast',
      },
    });
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_add_agents',
      params: {
        accountId: 530,
        inbox_id: 4769,
      },
      query: { provider: 'binotel' },
    });
  });

  it('does not require shared Sipuni credentials before creating a Virtual PBX channel', async () => {
    routeMock.query = { provider: 'sipuni' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { ui_config: { inbox_id: 202 }, errors: [] },
    });
    const wrapper = buildWrapper();
    const inputs = wrapper.findAll('input');

    await inputs[0].setValue('Virtual PBX');
    await inputs[1].setValue('+1 555 123 4567');
    await inputs[2].setValue('sip.provider.local');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    const [payload] = createVirtualPbxChannelMock.mock.calls[0];
    expect(payload.connection).toMatchObject({ host: 'sip.provider.local' });
    expect(payload.connection).not.toHaveProperty('password');
  });

  it('keeps Sipuni create form free of provider technical numbers and operator SIP AOR', async () => {
    routeMock.query = { provider: 'kazakhstan' };
    const wrapper = buildWrapper();

    wrapper.vm.isVirtualPbxAdvancedVisible = true;
    await wrapper.vm.$nextTick();

    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_ACCOUNT_NUMBER.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INGRESS_NUMBER.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_AOR.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.TRANSPORT.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.LABEL'
    );
  });

  it('creates a direct Asterisk analog channel from the provider card route', async () => {
    routeMock.query = { provider: 'asterisk_analog' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { ui_config: { inbox_id: 9098 }, errors: [] },
    });
    const wrapper = buildWrapper();
    const inputs = wrapper.findAll('input');

    await inputs[0].setValue('Asterisk analog 9098');
    await inputs[1].setValue('+7 717 270 5175');
    await inputs[2].setValue('10.77.0.5');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.LABEL'
    );
    const [payload, options] = createVirtualPbxChannelMock.mock.calls[0];
    expect(options).toEqual({ dryRun: false, remoteCommit: false });
    expect(payload).toMatchObject({
      provider_kind: 'asterisk_analog',
      channel_name: 'Asterisk analog 9098',
      display_phone_number: '+77172705175',
      provider_account_number: '+77172705175',
      ingress_number: '+77172705175',
      connection: {
        host: '10.77.0.5',
        port: '5060',
        transport: 'udp',
      },
      metadata: {
        source: 'virtual_pbx_ui',
        outbound_dial_format: 'kz_trunk',
      },
    });
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_add_agents',
      params: {
        accountId: 530,
        inbox_id: 9098,
      },
      query: { provider: 'asterisk_analog' },
    });
  });

  it('creates an Asterisk analog channel with configurable provider connection', async () => {
    routeMock.query = { provider: 'kazakhstan' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { ui_config: { inbox_id: 202 }, errors: [] },
    });
    const wrapper = buildWrapper();

    Object.assign(wrapper.vm.kazakhstanState, {
      providerKind: 'asterisk_analog',
      channelName: 'Asterisk analog',
      phoneNumber: '+1 555 123 4567',
      connectionHost: '10.77.0.5',
      connectionPort: '5070',
      connectionTransport: 'udp',
    });
    wrapper.vm.isVirtualPbxAdvancedVisible = true;
    await wrapper.vm.$nextTick();
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.TRANSPORT.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_USERNAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PASSWORD.LABEL'
    );
    const [payload, options] = createVirtualPbxChannelMock.mock.calls[0];
    expect(options).toEqual({ dryRun: false, remoteCommit: false });
    expect(payload).toMatchObject({
      provider_kind: 'asterisk_analog',
      channel_name: 'Asterisk analog',
      connection: {
        host: '10.77.0.5',
        port: '5070',
        transport: 'udp',
      },
      routing: {
        mode: 'operator',
        fallback_mode: 'reject',
        operator_distribution_mode: 'broadcast',
      },
      metadata: {
        source: 'virtual_pbx_ui',
        outbound_dial_format: 'kz_trunk',
      },
    });
    expect(payload.provider_account_number).toBe(payload.display_phone_number);
    expect(payload.ingress_number).toBe(payload.display_phone_number);
    expect(payload).not.toHaveProperty('profiles');
    expect(payload.connection).not.toHaveProperty('username');
    expect(payload.connection).not.toHaveProperty('password');
  });

  it('shows employee extension and SIP credential fields during channel creation', async () => {
    routeMock.query = { provider: 'sipuni' };
    agentListMock.push({ id: 179, name: 'Agent One' });
    const wrapper = buildWrapper();

    wrapper.vm.handleEmployeeAdd({ value: 179 });
    await wrapper.vm.$nextTick();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
    );
  });

  it('omits blank optional SIP credentials from an employee profile', () => {
    routeMock.query = { provider: 'sipuni' };
    const wrapper = buildWrapper();
    wrapper.vm.employeeProfiles = [
      {
        userId: 179,
        name: 'Agent One',
        internalExtension: '505',
        sipUsername: '',
        sipPassword: '',
        enabled: true,
      },
    ];

    expect(wrapper.vm.getVirtualPbxPayload().profiles).toEqual([
      {
        profile_kind: 'human_operator',
        user_id: 179,
        internal_extension: '505',
        enabled: true,
      },
    ]);
  });

  it('creates Sipuni employee membership and SIP profile in the initial request', async () => {
    routeMock.query = { provider: 'sipuni' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { ui_config: { inbox_id: 4778 }, errors: [] },
    });
    const wrapper = buildWrapper();
    Object.assign(wrapper.vm.kazakhstanState, {
      channelName: 'Sipuni with operator',
      phoneNumber: '+7 700 000 0088',
      connectionHost: 'ats01.kz.sipuni.com',
    });
    wrapper.vm.employeeProfiles = [
      {
        userId: 179,
        name: 'Agent One',
        internalExtension: '505',
        sipUsername: 'employee-505',
        sipPassword: 'profile-secret',
        enabled: true,
      },
    ];

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createVirtualPbxChannelMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider_kind: 'sipuni',
        profiles: [
          {
            profile_kind: 'human_operator',
            user_id: 179,
            internal_extension: '505',
            sip_username: 'employee-505',
            sip_password: 'profile-secret',
            enabled: true,
          },
        ],
      }),
      { dryRun: false, remoteCommit: false }
    );
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inbox_finish',
      params: {
        accountId: 530,
        inbox_id: 4778,
      },
    });
  });

  it('does not create a channel when a selected employee has no extension', async () => {
    routeMock.query = { provider: 'sipuni' };
    const wrapper = buildWrapper();
    Object.assign(wrapper.vm.kazakhstanState, {
      channelName: 'Sipuni invalid operator',
      phoneNumber: '+7 700 000 0099',
      connectionHost: 'ats01.kz.sipuni.com',
    });
    wrapper.vm.employeeProfiles = [
      {
        userId: 179,
        name: 'Agent One',
        internalExtension: '',
        sipUsername: 'employee-505',
        sipPassword: 'profile-secret',
        enabled: true,
      },
    ];

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createVirtualPbxChannelMock).not.toHaveBeenCalled();
    expect(alertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.REQUIRED'
    );
  });
});
