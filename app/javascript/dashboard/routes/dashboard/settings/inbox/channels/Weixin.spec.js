import { shallowMount } from '@vue/test-utils';

import Weixin from './Weixin.vue';

const routerReplaceMock = vi.hoisted(() => vi.fn());

vi.mock('../../../../index', () => ({
  default: {
    replace: routerReplaceMock,
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const buildWrapper = ({ dispatch = vi.fn() } = {}) =>
  shallowMount(Weixin, {
    global: {
      mocks: {
        $t: key => key,
        $route: {
          name: 'settings_inboxes_page_channel',
          params: { accountId: 1 },
          query: {},
        },
        $store: {
          getters: {
            'inboxes/getUIFlags': { isCreating: false },
          },
          dispatch,
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
    const dispatch = vi.fn(action => {
      if (action === 'inboxes/createChannel') {
        return Promise.resolve({ id: 42 });
      }

      if (action === 'inboxes/requestWeixinQr') {
        return Promise.resolve({ id: 42 });
      }

      return Promise.resolve();
    });
    const wrapper = buildWrapper({ dispatch });

    await wrapper.vm.createChannel();

    expect(dispatch).toHaveBeenNthCalledWith(1, 'inboxes/createChannel', {
      channel: { type: 'weixin' },
    });
    expect(dispatch).toHaveBeenNthCalledWith(2, 'inboxes/requestWeixinQr', 42);
    expect(routerReplaceMock).toHaveBeenCalledWith({
      name: 'settings_inbox_finish',
      params: { inbox_id: 42 },
      query: { channel_type: 'weixin' },
    });
  });

  it('sends the optional display name when it is present', async () => {
    const dispatch = vi.fn(action => {
      if (action === 'inboxes/createChannel') {
        return Promise.resolve({ id: 43 });
      }

      if (action === 'inboxes/requestWeixinQr') {
        return Promise.resolve({ id: 43 });
      }

      return Promise.resolve();
    });
    const wrapper = buildWrapper({ dispatch });

    await wrapper.find('input').setValue('  Main WeChat  ');
    await wrapper.vm.createChannel();

    expect(dispatch).toHaveBeenNthCalledWith(1, 'inboxes/createChannel', {
      channel: {
        type: 'weixin',
        display_name: 'Main WeChat',
      },
    });
  });
});
