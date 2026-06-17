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
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
  }),
  useMapGetter: getter => ({
    value: getter === 'inboxes/getUIFlags' ? { isCreating: false } : {},
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
        ChannelSelector: true,
        Select: true,
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
    dispatchMock.mockResolvedValue({ id: 101 });
    routeMock.query = { provider: 'kazakhstan' };
  });

  it('does not expose the legacy direct Sipuni API setup form', () => {
    routeMock.query = { provider: 'sipuni' };
    const wrapper = buildWrapper();

    expect(wrapper.find('form').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('INBOX_MGMT.ADD.VOICE.SIPUNI');
  });

  it('creates a Virtual PBX Sipuni channel without employee profiles', async () => {
    routeMock.query = { provider: 'kazakhstan' };
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
      { dryRun: false, remoteCommit: true }
    );
    expect(createVirtualPbxChannelMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider_kind: 'sipuni',
        channel_name: 'Virtual PBX',
        provider_account_number: '+15551234567',
        ingress_number: expect.any(String),
        connection: expect.objectContaining({
          host: 'sip.provider.local',
          port: '5060',
          transport: 'udp',
          username: undefined,
          password: undefined,
        }),
        routing: expect.objectContaining({
          mode: 'operator',
          fallback_mode: 'reject',
          operator_agent_aor: undefined,
        }),
        metadata: {
          source: 'virtual_pbx_ui',
        },
      }),
      { dryRun: false, remoteCommit: true }
    );
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_add_agents',
      params: {
        accountId: 530,
        inbox_id: 202,
      },
    });
  });

  it('does not require shared Sipuni credentials before creating a Virtual PBX channel', async () => {
    routeMock.query = { provider: 'kazakhstan' };
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
      expect.objectContaining({
        connection: expect.objectContaining({
          host: 'sip.provider.local',
          password: undefined,
        }),
      }),
      { dryRun: false, remoteCommit: true }
    );
  });

  it('points employee SIP assignment to settings instead of create', () => {
    routeMock.query = { provider: 'kazakhstan' };
    const wrapper = buildWrapper();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.CREATE_HINT'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
    );
  });
});
