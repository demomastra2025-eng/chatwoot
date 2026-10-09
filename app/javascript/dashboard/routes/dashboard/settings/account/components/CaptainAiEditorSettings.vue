<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useCaptainFeatureSettings } from 'dashboard/composables/captain/useCaptainFeatureSettings';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import SectionLayout from './SectionLayout.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();
const { saveCaptainFeatures } = useCaptainFeatureSettings();
const isLoading = ref(true);
const savingKey = ref('');
const loadFailed = ref(false);
const saveFailed = ref(false);
const features = computed(() => captainConfigStore.features);

const isTextImprovementEnabled = computed(
  () => features.value.editor?.enabled !== false
);
const isLabelSuggestionEnabled = computed(
  () => features.value.label_suggestion?.enabled === true
);

const saveFeature = async (key, enabled) => {
  savingKey.value = key;
  saveFailed.value = false;
  try {
    await saveCaptainFeatures({ [key]: enabled });
  } catch (error) {
    saveFailed.value = true;
  } finally {
    savingKey.value = '';
  }
};

onMounted(async () => {
  await captainConfigStore.fetch({ clientMetadataOnly: true });
  loadFailed.value = captainConfigStore.uiFlags.fetchError === true;
  isLoading.value = false;
});
</script>

<template>
  <SectionLayout
    :title="t('CAPTAIN_SETTINGS.FEATURES.TITLE')"
    :description="t('CAPTAIN_SETTINGS.FEATURES.DESCRIPTION')"
    with-border
  >
    <div v-if="isLoading" class="text-sm text-n-slate-11" role="status">
      {{ t('CAPTAIN_SETTINGS.LOADING') }}
    </div>
    <p v-else-if="loadFailed" class="m-0 text-sm text-n-ruby-9" role="alert">
      {{ t('CAPTAIN_SETTINGS.API.ERROR') }}
    </p>
    <div v-else class="grid gap-4">
      <div
        class="flex items-center justify-between gap-4"
        data-test="captain-text-improvement"
      >
        <div class="min-w-0">
          <div class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN_SETTINGS.FEATURES.TEXT_IMPROVEMENT.TITLE') }}
          </div>
          <div class="text-xs text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.FEATURES.TEXT_IMPROVEMENT.DESCRIPTION') }}
          </div>
        </div>
        <Switch
          :model-value="isTextImprovementEnabled"
          :disabled="savingKey === 'text_improvement'"
          @change="enabled => saveFeature('text_improvement', enabled)"
        />
      </div>
      <div
        class="flex items-center justify-between gap-4"
        data-test="captain-label-suggestion"
      >
        <div class="min-w-0">
          <div class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.TITLE') }}
          </div>
          <div class="text-xs text-n-slate-11">
            {{ t('CAPTAIN_SETTINGS.FEATURES.LABEL_SUGGESTION.DESCRIPTION') }}
          </div>
        </div>
        <Switch
          :model-value="isLabelSuggestionEnabled"
          :disabled="savingKey === 'label_suggestion'"
          @change="enabled => saveFeature('label_suggestion', enabled)"
        />
      </div>
      <p v-if="saveFailed" class="m-0 text-sm text-n-ruby-9" role="alert">
        {{ t('CAPTAIN_SETTINGS.API.ERROR') }}
      </p>
    </div>
  </SectionLayout>
</template>
