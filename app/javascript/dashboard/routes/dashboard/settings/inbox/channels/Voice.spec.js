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
    routeMock.query = { provider: 'sipuni' };
  });

  it('normalizes Sipuni phone input before creating the voice inbox', async () => {
    const wrapper = buildWrapper();
    const inputs = wrapper.findAll('input');

    await inputs[0].setValue('+7 727 123-45-67');
    await inputs[1].setValue('  123456  ');
    await inputs[2].setValue('  integration-key  ');
    await inputs[3].setValue('  100  ');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('inboxes/createVoiceChannel', {
      name: '+77271234567',
      voice: {
        phone_number: '+77271234567',
        provider: 'sipuni',
        provider_config: {
          account_number: '123456',
          default_internal_number: '100',
          integration_secret: 'integration-key',
          audio_mode: 'external_softphone',
        },
      },
    });
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_add_agents',
      params: {
        accountId: 530,
        inbox_id: 101,
      },
    });
  });

  it('creates a simple local Virtual PBX channel without employee profiles', async () => {
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
      { dryRun: false, remoteCommit: false }
    );
    expect(createVirtualPbxChannelMock).toHaveBeenCalledWith(
      expect.objectContaining({
        provider_kind: 'sipuni',
        channel_name: 'Virtual PBX',
        provider_account_number: expect.any(String),
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
      { dryRun: false, remoteCommit: false }
    );
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inboxes_add_agents',
      params: {
        accountId: 530,
        inbox_id: 202,
      },
    });
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
