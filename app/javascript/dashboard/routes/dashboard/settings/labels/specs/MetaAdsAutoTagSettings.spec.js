import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import MetaAdsAutoTagSettings from '../MetaAdsAutoTagSettings.vue';
import MetaAdsSettingsAPI from 'dashboard/api/metaAdsSettings';

vi.mock('dashboard/api/metaAdsSettings', () => ({
  default: {
    get: vi.fn(),
    updateSettings: vi.fn(),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

const mockIsAdmin = ref(true);
vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: mockIsAdmin }),
}));

const mockLabels = ref([
  { id: 1, title: 'meta_ads', display_title: 'Meta Ads', color: '#1F93FF' },
  { id: 2, title: 'checkup_30', display_title: 'Чекап -30%', color: '#22C55E' },
]);

vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({
    'labels/getLabels': mockLabels,
  }),
}));

describe('MetaAdsAutoTagSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIsAdmin.value = true;
    MetaAdsSettingsAPI.get.mockResolvedValue({
      data: {
        auto_tag_enabled: true,
        system_label: {
          id: 1,
          title: 'meta_ads',
          display_title: 'Meta Ads',
          color: '#1F93FF',
          exists: true,
        },
        source_rules: [],
        recent_sources: [
          {
            source_id: '120214555001',
            headline: 'Чекап клиники -30%',
            referrals_count: 3,
          },
        ],
      },
    });
  });

  const mountComponent = () =>
    mount(MetaAdsAutoTagSettings, {
      global: {
        mocks: {
          $t: (key, params) =>
            params?.count !== undefined ? `${key}:${params.count}` : key,
        },
        stubs: {
          Switch: {
            props: ['modelValue', 'disabled'],
            emits: ['change'],
            template:
              '<button data-testid="meta-ads-autotag-toggle" :disabled="disabled" @click="$emit(\'change\', !modelValue)">{{ modelValue }}</button>',
          },
          Button: {
            props: ['label', 'disabled', 'type'],
            emits: ['click'],
            template:
              '<button :type="type || \'button\'" :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
          },
        },
      },
    });

  it('loads default-enabled Meta Ads setting and toggles it via API', async () => {
    MetaAdsSettingsAPI.updateSettings.mockResolvedValueOnce({
      data: {
        auto_tag_enabled: false,
        source_rules: [],
        recent_sources: [],
      },
    });

    const wrapper = mountComponent();
    await flushPromises();

    const toggle = wrapper.find('[data-testid="meta-ads-autotag-toggle"]');
    expect(toggle.text()).toBe('true');

    await toggle.trigger('click');
    await flushPromises();

    expect(MetaAdsSettingsAPI.updateSettings).toHaveBeenCalledWith({
      auto_tag_enabled: false,
    });
    expect(wrapper.emitted('updated')).toBeTruthy();
    expect(toggle.text()).toBe('false');
  });

  it('picks a recent ad creative and saves a source_id -> label rule', async () => {
    MetaAdsSettingsAPI.updateSettings.mockResolvedValueOnce({
      data: {
        auto_tag_enabled: true,
        source_rules: [
          {
            source_id: '120214555001',
            label_ids: [2],
            labels: [
              {
                id: 2,
                title: 'checkup_30',
                display_title: 'Чекап -30%',
                color: '#22C55E',
              },
            ],
          },
        ],
        recent_sources: [],
      },
    });

    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .find('[data-testid="meta-ads-rules-expand-btn"]')
      .trigger('click');

    const chip = wrapper.find('[data-testid="meta-ads-recent-source-chip"]');
    expect(chip.exists()).toBe(true);
    await chip.trigger('click');

    const input = wrapper.find('[data-testid="meta-ads-rule-source-input"]');
    expect(input.element.value).toBe('120214555001');

    const select = wrapper.find('[data-testid="meta-ads-rule-label-select"]');
    await select.setValue('2');

    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(MetaAdsSettingsAPI.updateSettings).toHaveBeenCalledWith({
      source_rules: [{ source_id: '120214555001', label_ids: [2] }],
    });
    expect(wrapper.findAll('[data-testid="meta-ads-rule-row"]')).toHaveLength(
      1
    );
  });
});
