import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { ref } from 'vue';

import StatusBanner from './StatusBanner.vue';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';

const globalConfig = ref({ activePlatformBanners: [] });
const storage = { value: [] };

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: vi.fn(() => globalConfig),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => (key === 'GENERAL_SETTINGS.DISMISS' ? 'Dismiss' : key),
  }),
}));

vi.mock('shared/helpers/localStorage', () => ({
  LocalStorage: {
    get: vi.fn(() => storage.value),
    set: vi.fn((key, value) => {
      storage.value = value;
    }),
  },
}));

const BannerStub = {
  name: 'Banner',
  props: {
    color: {
      type: String,
      default: 'slate',
    },
    actionLabel: {
      type: String,
      default: null,
    },
  },
  emits: ['action'],
  template:
    '<section data-test-id="banner" :data-color="color"><slot /><button @click="$emit(\'action\')">{{ actionLabel }}</button></section>',
};

const htmlDirective = {
  beforeMount(el, binding) {
    el.innerHTML = binding.value;
  },
  updated(el, binding) {
    el.innerHTML = binding.value;
  },
};

function mountComponent() {
  return shallowMount(StatusBanner, {
    global: {
      stubs: {
        Banner: BannerStub,
      },
      directives: {
        'dompurify-html': htmlDirective,
      },
    },
  });
}

describe('StatusBanner', () => {
  beforeEach(() => {
    storage.value = [];
    globalConfig.value = {
      activePlatformBanners: [
        {
          id: 1,
          banner_message:
            'Meta APIs degraded. [Status](https://status.one-link.kz)',
          banner_type: 'warning',
          updated_at: '2026-05-27T08:00:00Z',
        },
      ],
    };
  });

  it('renders active platform banners from global config', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('[data-test-id="banner"]').attributes('data-color')
    ).toBe('amber');
    expect(wrapper.text()).toContain('Meta APIs degraded');
    expect(wrapper.html()).toContain('https://status.one-link.kz');
  });

  it('normalizes malformed dismiss state from localStorage', () => {
    storage.value = 'not-an-array';

    const wrapper = mountComponent();

    expect(wrapper.find('[data-test-id="banner"]').exists()).toBe(true);
  });

  it('stores a versioned dismiss key and hides dismissed banners', async () => {
    const wrapper = mountComponent();

    await wrapper.find('button').trigger('click');

    expect(storage.value).toEqual(['1-2026-05-27T08:00:00Z']);
    expect(LOCAL_STORAGE_KEYS.DISMISSED_PLATFORM_BANNERS).toBe(
      'dismissedPlatformBanners'
    );
    expect(wrapper.find('[data-test-id="banner"]').exists()).toBe(false);
  });
});
