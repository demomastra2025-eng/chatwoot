import { shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { useInboxStore } from 'dashboard/stores/inboxes';

import Weixin from './Weixin.vue';

const routerReplaceMock = vi.hoisted(() => vi.fn());
let pinia;

vi.mock('../../../../index', () => ({
  default: {
    replace: routerReplaceMock,
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const buildWrapper = () =>
  shallowMount(Weixin, {
    global: {
      plugins: [pinia],
      mocks: {
        $t: key => key,
        $route: {
          name: 'settings_inboxes_page_channel',
          params: { accountId: 1 },
          query: {},
        },
      },
      stubs: {
        PageHeader: true,
        NextButton: true,
      },
    },
  });

describe('Weixin channel setup', () => {
  beforeEach(() => {
    pinia = createPinia();
    setActivePinia(pinia);
    routerReplaceMock.mockClear();
  });

  it('only asks for an optional display name before QR login', () => {
    const wrapper = buildWrapper();

    expect(wrapper.findAll('input')).toHaveLength(1);
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.WEIXIN_CHANNEL.ILINK_TOKEN.LABEL'
    );
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ADD.WEIXIN_CHANNEL.PROVIDER_ACCOUNT_ID.LABEL'
    );
  });

  it('creates a QR-first channel without sending manual iLink fields', async () => {
    const store = useInboxStore();
    const createChannel = vi
      .spyOn(store, 'createChannel')
      .mockResolvedValue({ id: 42 });
    const requestWeixinQr = vi
      .spyOn(store, 'requestWeixinQr')
      .mockResolvedValue({ id: 42 });
    const wrapper = buildWrapper();

    await wrapper.vm.createChannel();

    expect(createChannel).toHaveBeenCalledWith({
      channel: { type: 'weixin' },
    });
    expect(requestWeixinQr).toHaveBeenCalledWith(42);
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inbox_finish',
      params: { inbox_id: 42 },
      query: { channel_type: 'weixin' },
    });
  });

  it('sends the optional display name when it is present', async () => {
    const store = useInboxStore();
    const createChannel = vi
      .spyOn(store, 'createChannel')
      .mockResolvedValue({ id: 43 });
    vi.spyOn(store, 'requestWeixinQr').mockResolvedValue({ id: 43 });
    const wrapper = buildWrapper();

    await wrapper.find('input').setValue('  Main WeChat  ');
    await wrapper.vm.createChannel();

    expect(createChannel).toHaveBeenCalledWith({
      channel: {
        type: 'weixin',
        display_name: 'Main WeChat',
      },
    });
  });
});
