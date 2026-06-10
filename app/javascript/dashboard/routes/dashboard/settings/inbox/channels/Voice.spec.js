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
    value: getter === 'getCurrentUser' ? { id: 501 } : { isCreating: false },
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

  it('creates a local Virtual PBX channel with current user profile', async () => {
    routeMock.query = { provider: 'kazakhstan' };
    createVirtualPbxChannelMock.mockResolvedValue({
      payload: { config: { inbox_id: 202 }, errors: [] },
    });
    const wrapper = buildWrapper();
    const inputs = wrapper.findAll('input');

    await inputs[0].setValue('Virtual PBX');
    await inputs[1].setValue('+7 727 123-45-67');
    await inputs[3].setValue('3100000');
    await inputs[4].setValue('sip.provider.local');
    await inputs[8].setValue('100');
    await inputs[9].setValue('sip:100@sip.provider.local');
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createVirtualPbxChannelMock).toHaveBeenCalledWith(
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
          username: undefined,
          password: undefined,
        },
        routing: {
          mode: 'operator',
          fallback_mode: 'reject',
          operator_agent_aor: 'sip:100@sip.provider.local',
        },
        profiles: [
          {
            user_id: 501,
            internal_extension: '100',
            enabled: true,
          },
        ],
        metadata: {
          source: 'virtual_pbx_ui',
        },
      },
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
});
