<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  TEXT_IMPROVEMENT_SETTING_KEY,
  useCaptainFeatureSettings,
} from 'dashboard/composables/captain/useCaptainFeatureSettings';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import SectionLayout from './SectionLayout.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';

const props = defineProps({
  disabled: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();
const { saveCaptainFeatures } = useCaptainFeatureSettings();
const isLoading = ref(true);
const savingKey = ref('');
const loadFailed = ref(false);
const saveFailed = ref(false);
const features = computed(() => captainConfigStore.features);
const featureValues = ref({ textImprovement: false, labelSuggestion: false });

const featureValuesFromStore = () => ({
  // The preferences serializer exposes captain_features.text_improvement as editor.enabled.
  textImprovement: features.value.editor?.enabled === true,
  labelSuggestion: features.value.label_suggestion?.enabled === true,
});
const isTextImprovementEnabled = computed(
  () => featureValues.value.textImprovement
);
const isLabelSuggestionEnabled = computed(
  () => featureValues.value.labelSuggestion
);

let saveQueue = Promise.resolve();
let pendingSaveCount = 0;

const saveFeature = async (key, enabled) => {
  const requestedValues = { ...featureValues.value, [key]: enabled };
  featureValues.value = requestedValues;
  savingKey.value = key;
  saveFailed.value = false;
  pendingSaveCount += 1;
  const request = saveQueue.then(() =>
    saveCaptainFeatures({
      [TEXT_IMPROVEMENT_SETTING_KEY]: requestedValues.textImprovement,
      label_suggestion: requestedValues.labelSuggestion,
    })
  );
  // Keep responses ordered so a slower previous request cannot replace a newer toggle state.
  saveQueue = request.then(
    () => undefined,
    () => undefined
  );

  try {
    await request;
    saveFailed.value = false;
  } catch (error) {
    saveFailed.value = true;
    if (pendingSaveCount === 1) featureValues.value = featureValuesFromStore();
  } finally {
    pendingSaveCount -= 1;
    if (pendingSaveCount === 0) savingKey.value = '';
  }
};

const loadSettings = async ({ force = false } = {}) => {
  isLoading.value = true;
  loadFailed.value = false;
  try {
    await captainConfigStore.fetch(
      force
        ? { clientMetadataOnly: true, force: true }
        : { clientMetadataOnly: true }
    );
    loadFailed.value = captainConfigStore.uiFlags.fetchError === true;
    if (!loadFailed.value && pendingSaveCount === 0) {
      featureValues.value = featureValuesFromStore();
    }
  } catch (error) {
    loadFailed.value = true;
  } finally {
    isLoading.value = false;
  }
};

onMounted(loadSettings);
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
    <div v-else-if="loadFailed" class="flex flex-wrap items-center gap-3">
      <p class="m-0 text-sm text-n-ruby-9" role="alert">
        {{ t('CAPTAIN_SETTINGS.API.ERROR') }}
      </p>
      <button
        type="button"
        class="text-sm font-medium text-n-brand hover:underline"
        @click="loadSettings({ force: true })"
      >
        {{ t('DESIGN_SYSTEM.STATE.RETRY') }}
      </button>
    </div>
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
          :disabled="props.disabled || savingKey !== ''"
          @change="enabled => saveFeature('textImprovement', enabled)"
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
          :disabled="props.disabled || savingKey !== ''"
          @change="enabled => saveFeature('labelSuggestion', enabled)"
        />
      </div>
      <p v-if="saveFailed" class="m-0 text-sm text-n-ruby-9" role="alert">
        {{ t('CAPTAIN_SETTINGS.API.ERROR') }}
      </p>
    </div>
  </SectionLayout>
</template>
