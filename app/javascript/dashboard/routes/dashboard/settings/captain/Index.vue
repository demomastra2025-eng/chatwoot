<script setup>
import { computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { storeToRefs } from 'pinia';
import { useAlert } from 'dashboard/composables';
import { useCaptain } from 'dashboard/composables/useCaptain';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import {
  TEXT_IMPROVEMENT_SETTING_KEY,
  useCaptainFeatureSettings,
} from 'dashboard/composables/captain/useCaptainFeatureSettings';
import { formatBytes } from 'shared/helpers/FileHelper';

import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SectionLayout from '../account/components/SectionLayout.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CaptainPaywall from 'next/captain/pageComponents/Paywall.vue';

const { t } = useI18n();
const { captainEnabled } = useCaptain();
const captainConfigStore = useCaptainConfigStore();
const { saveCaptainFeatures } = useCaptainFeatureSettings();
const { uiFlags, runtime, runtimeMetadata, features } =
  storeToRefs(captainConfigStore);

const isFirecrawlConfigured = computed(
  () => runtimeMetadata.value?.web_access?.configured === true
);
const isTextImprovementEnabled = computed(
  () => features.value.editor?.enabled !== false
);
const isLabelSuggestionEnabled = computed(
  () => features.value.label_suggestion?.enabled === true
);
const webAccessItems = computed(() => {
  const metadata = runtimeMetadata.value?.web_access || {};
  const numberFormatter = new Intl.NumberFormat();
  return [
    {
      key: 'web_search_enabled',
      title: t('CAPTAIN_SETTINGS.WEB_ACCESS.SEARCH.TITLE'),
      description: t('CAPTAIN_SETTINGS.WEB_ACCESS.SEARCH.DESCRIPTION'),
      limit: t('CAPTAIN_SETTINGS.WEB_ACCESS.SEARCH.LIMIT', {
        count: runtime.value.web_search_max_results ||
          metadata.search_default_results || 5,
      }),
    },
    {
      key: 'web_scrape_enabled',
      title: t('CAPTAIN_SETTINGS.WEB_ACCESS.SCRAPE.TITLE'),
      description: t('CAPTAIN_SETTINGS.WEB_ACCESS.SCRAPE.DESCRIPTION'),
      limit: t('CAPTAIN_SETTINGS.WEB_ACCESS.SCRAPE.LIMIT', {
        count: numberFormatter.format(runtime.value.web_scrape_max_chars ||
          metadata.scrape_default_max_chars || 12000),
      }),
    },
    {
      key: 'web_document_parse_enabled',
      title: t('CAPTAIN_SETTINGS.WEB_ACCESS.DOCUMENTS.TITLE'),
      description: t('CAPTAIN_SETTINGS.WEB_ACCESS.DOCUMENTS.DESCRIPTION'),
      limit: t('CAPTAIN_SETTINGS.WEB_ACCESS.DOCUMENTS.LIMIT', {
        count: numberFormatter.format(runtime.value.web_document_parse_max_chars ||
          metadata.document_parse_default_max_chars || 24000),
        size: formatBytes(metadata.document_parse_max_file_bytes || 0, 0),
      }),
    },
  ];
});

async function handleFeatureToggle(feature, enabled) {
  try {
    await saveCaptainFeatures({ [feature]: enabled });
    useAlert(t('CAPTAIN_SETTINGS.API.SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.API.ERROR'));
    captainConfigStore.fetch({ clientMetadataOnly: true });
  }
}

async function handleRuntimeToggle(key, enabled) {
  try {
    await captainConfigStore.updatePreferences({
      captain_runtime: { [key]: enabled },
    });
    useAlert(t('CAPTAIN_SETTINGS.API.SUCCESS'));
  } catch (error) {
    useAlert(t('CAPTAIN_SETTINGS.API.ERROR'));
    captainConfigStore.fetch({ clientMetadataOnly: true });
  }
}

onMounted(() => {
  captainConfigStore.fetch({ clientMetadataOnly: true });
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :no-records-message="t('CAPTAIN_SETTINGS.NOT_ENABLED')"
    :loading-message="t('CAPTAIN_SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="t('CAPTAIN_SETTINGS.TITLE')"
        :description="t('CAPTAIN_SETTINGS.DESCRIPTION')"
        icon-name="captain"
      />
    </template>
    <template #body>
      <div v-if="captainEnabled" class="flex flex-col gap-8">
        <SectionLayout
          :title="t('CAPTAIN_SETTINGS.WEB_ACCESS.TITLE')"
          :description="t('CAPTAIN_SETTINGS.WEB_ACCESS.DESCRIPTION')"
          with-border
        >
          <div class="grid gap-3" data-test="captain-web-access-section">
            <div
              v-for="item in webAccessItems"
              :key="item.key"
              class="flex items-center justify-between gap-4 rounded-xl border border-n-weak
                bg-n-solid-1 p-4"
            >
              <div>
                <div class="text-sm font-medium text-n-slate-12">
                  {{ item.title }}
                </div>
                <div class="text-xs text-n-slate-11">
                  {{ item.description }} {{ item.limit }}
                </div>
              </div>
              <Switch
                :model-value="runtime[item.key] === true"
                :disabled="!isFirecrawlConfigured"
                @change="enabled => handleRuntimeToggle(item.key, enabled)"
              />
            </div>
          </div>
        </SectionLayout>

        <SectionLayout :title="t('CAPTAIN_SETTINGS.FEATURES.TITLE')">
          <div class="grid gap-3">
            <div
              class="flex items-center justify-between gap-4"
              data-test="captain-text-improvement"
            >
              <div>
                <div class="text-sm font-medium text-n-slate-12">
                  {{ t('CAPTAIN_SETTINGS.FEATURES.TEXT_IMPROVEMENT.TITLE') }}
                </div>
                <div class="text-xs text-n-slate-11">
                  {{ t('CAPTAIN_SETTINGS.FEATURES.TEXT_IMPROVEMENT.DESCRIPTION') }}
                </div>
              </div>
              <Switch
                :model-value="isTextImprovementEnabled"
                @change="
                  enabled =>
                    handleFeatureToggle(TEXT_IMPROVEMENT_SETTING_KEY, enabled)
                "
              />
            </div>
            <div class="flex items-center justify-between gap-4">
              <div>
                <div class="text-sm font-medium text-n-slate-12">
                  {{ t('CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.TITLE') }}
                </div>
                <div class="text-xs text-n-slate-11">
                  {{ t('CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.DESCRIPTION') }}
                </div>
              </div>
              <Switch
                :model-value="isLabelSuggestionEnabled"
                @change="enabled => handleFeatureToggle('label_suggestion', enabled)"
              />
            </div>
            <div class="flex items-center justify-between gap-4">
              <div>
                <div class="text-sm font-medium text-n-slate-12">
                  {{ t('CAPTAIN_SETTINGS.RUNTIME.MODERATION.TITLE') }}
                </div>
                <div class="text-xs text-n-slate-11">
                  {{ t('CAPTAIN_SETTINGS.RUNTIME.MODERATION.DESCRIPTION') }}
                </div>
              </div>
              <Switch
                :model-value="runtime.assistant_moderation === true"
                @change="enabled => handleRuntimeToggle('assistant_moderation', enabled)"
              />
            </div>
          </div>
        </SectionLayout>
      </div>
      <CaptainPaywall v-else />
    </template>
  </SettingsLayout>
</template>
