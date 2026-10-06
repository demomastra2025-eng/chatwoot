import { shallowMount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import Index from './Index.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({ captainEnabled: true }),
}));
vi.mock('dashboard/composables/captain/useCaptainFeatureSettings', () => ({
  TEXT_IMPROVEMENT_SETTING_KEY: 'text_improvement',
  useCaptainFeatureSettings: () => ({ saveCaptainFeatures: vi.fn() }),
}));

const mountComponent = (store, pinia) => {
  vi.spyOn(store, 'fetch').mockResolvedValue();
  return shallowMount(Index, {
    global: {
      plugins: [pinia],
      stubs: {
        SettingsLayout: {
          template: '<main><slot name="header" /><slot name="body" /></main>',
        },
        BaseSettingsHeader: true,
        SectionLayout: { template: '<section><slot /></section>' },
        Switch: true,
        CaptainPaywall: true,
      },
    },
  });
};

describe('Captain AI settings', () => {
  let store;
  let pinia;

  beforeEach(() => {
    pinia = createPinia();
    setActivePinia(pinia);
    store = useCaptainConfigStore();
    store.runtime = { assistant_moderation: true };
    store.runtimeMetadata = { web_access: { configured: true } };
    store.features = { editor: { enabled: true }, label_suggestion: {} };
  });

  it('loads settings without usage data', () => {
    mountComponent(store, pinia);
    expect(store.fetch).toHaveBeenCalledWith({ clientMetadataOnly: true });
  });

  it('renders only the retained controls', () => {
    const wrapper = mountComponent(store, pinia);
    const text = wrapper.text();
    expect(text).toContain('CAPTAIN_SETTINGS.WEB_ACCESS.SEARCH.TITLE');
    expect(text).toContain('CAPTAIN_SETTINGS.WEB_ACCESS.SCRAPE.TITLE');
    expect(text).toContain('CAPTAIN_SETTINGS.WEB_ACCESS.DOCUMENTS.TITLE');
    expect(text).toContain('CAPTAIN_SETTINGS.FEATURES.TEXT_IMPROVEMENT.TITLE');
    expect(text).toContain('CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.TITLE');
    expect(text).toContain('CAPTAIN_SETTINGS.RUNTIME.MODERATION.TITLE');
    expect(text).not.toContain('CAPTAIN_SETTINGS.RELIABILITY');
    expect(text).not.toContain('CAPTAIN_SETTINGS.USAGE');
    expect(text).not.toContain('CAPTAIN_SETTINGS.PROVIDER_KEYS');
    expect(text).not.toContain('CAPTAIN_SETTINGS.MODEL_CONFIG');
  });

  it('updates only the assistant safety switch', async () => {
    vi.spyOn(store, 'updatePreferences').mockResolvedValue();
    const wrapper = mountComponent(store, pinia);
    const switches = wrapper.findAllComponents({ name: 'Switch' });
    await switches.at(-1).vm.$emit('change', false);
    expect(store.updatePreferences).toHaveBeenCalledWith({
      captain_runtime: { assistant_moderation: false },
    });
  });
});
