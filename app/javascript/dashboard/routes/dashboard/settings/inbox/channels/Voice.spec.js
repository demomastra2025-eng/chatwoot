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
  useMapGetter: () => ({
    isCreating: false,
  }),
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
    dispatchMock.mockResolvedValue({ id: 101 });
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
});
