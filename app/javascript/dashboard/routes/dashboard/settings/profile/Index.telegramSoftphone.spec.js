import { shallowMount, enableAutoUnmount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { ref } from 'vue';
import ProfileSettings from './Index.vue';
import TelegramSoftphoneCard from './TelegramSoftphoneCard.vue';

enableAutoUnmount(afterEach);
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    isEditorHotKeyEnabled: () => false,
    updateUISettings: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/useFontSize', () => ({
  useFontSize: () => ({ currentFontSize: ref('16'), updateFontSize: vi.fn() }),
}));
vi.mock('shared/composables/useBranding', () => ({
  useBranding: () => ({ replaceInstallationName: value => value }),
}));

const mountProfile = allowed => {
  const store = createStore({
    state: { allowed },
    getters: {
      getCurrentUser: () => ({}),
      getCurrentUserID: () => null,
      'globalConfig/get': () => ({}),
      'accounts/isFeatureEnabledonAccount': state => (id, flag) =>
        id === 17 && flag === 'telegram_calls_bot' && state.allowed,
    },
    mutations: {
      setAllowed: (state, value) => {
        state.allowed = value;
      },
    },
  });
  return {
    store,
    wrapper: shallowMount(ProfileSettings, {
      global: {
        plugins: [store],
        mocks: { $route: { params: { accountId: '17' } }, $t: key => key },
        stubs: { SectionLayout: { template: '<section><slot /></section>' } },
      },
    }),
  };
};

describe('Profile Telegram bot entitlement', () => {
  it('does not mount the bot card or its section when access is off', () => {
    const { wrapper } = mountProfile(false);
    expect(wrapper.findComponent(TelegramSoftphoneCard).exists()).toBe(false);
  });

  it('mounts the existing card when enabled and removes it after revocation', async () => {
    const { wrapper, store } = mountProfile(true);
    expect(wrapper.findComponent(TelegramSoftphoneCard).exists()).toBe(true);
    store.commit('setAllowed', false);
    await wrapper.vm.$nextTick();
    expect(wrapper.findComponent(TelegramSoftphoneCard).exists()).toBe(false);
  });
});
