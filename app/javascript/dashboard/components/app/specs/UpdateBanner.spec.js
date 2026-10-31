import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { ref } from 'vue';
import UpdateBanner from '../UpdateBanner.vue';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import { LocalStorage } from 'shared/helpers/localStorage';

vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: ref(true) }),
}));

const mountBanner = props =>
  shallowMount(UpdateBanner, {
    props,
    global: {
      plugins: [
        createStore({
          getters: {
            'globalConfig/get': () => ({
              appVersion: '1.0.0',
              displayManifest: true,
            }),
          },
        }),
      ],
      stubs: {
        Banner: {
          name: 'Banner',
          props: ['bannerMessage', 'hrefLink'],
          template: '<div />',
        },
      },
    },
  });

describe('OneLink update banner contract', () => {
  beforeEach(() => localStorage.clear());

  it('prefers the new version and renders the existing locale placeholder with the official news link', () => {
    const wrapper = mountBanner({
      latestOnelinkVersion: '3.0.0',
      latestChatwootVersion: '2.0.0',
    });
    expect(wrapper.vm.bannerMessage).toContain('3.0.0');
    expect(wrapper.vm.bannerMessage).toContain('OneLink');
    expect(wrapper.vm.updateAvailable).toBe(true);
    expect(wrapper.vm.shouldShowBanner).toBe(true);
    expect(wrapper.findComponent({ name: 'Banner' }).props('hrefLink')).toBe(
      'https://t.me/onelink_ai'
    );
  });

  it('accepts the old version prop from cached callers and preserves the dismissal storage contract', () => {
    const wrapper = mountBanner({ latestChatwootVersion: '2.0.0' });
    expect(wrapper.vm.bannerMessage).toContain('2.0.0');
    wrapper.vm.dismissUpdateBanner();
    expect(LocalStorage.get(LOCAL_STORAGE_KEYS.DISMISSED_UPDATES)).toEqual([
      '2.0.0',
    ]);
  });
});
