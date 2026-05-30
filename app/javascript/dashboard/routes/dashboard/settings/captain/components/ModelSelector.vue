<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
import {
  hasSelectedModelDiagnostics,
  localizedDiagnosticReasons,
  selectedModelIdForDiagnostics,
} from '../helpers/modelDiagnostics';
import ModelDropdown from './ModelDropdown.vue';

const props = defineProps({
  featureKey: {
    type: String,
    required: true,
  },
  title: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    required: true,
  },
  isAllowed: {
    type: Boolean,
    required: true,
  },
  showControls: {
    type: Boolean,
    default: true,
  },
  models: {
    type: Array,
    default: null,
  },
});

const emit = defineEmits(['change']);
const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();

const availableModels = computed(
  () => props.models || captainConfigStore.getModelsForFeature(props.featureKey)
);
const featureConfig = computed(
  () => captainConfigStore.features?.[props.featureKey] || {}
);
const hasAvailableModels = computed(() => availableModels.value.length > 0);
const shouldShowSelectedDiagnostics = computed(() =>
  hasSelectedModelDiagnostics(featureConfig.value)
);
const selectedDiagnosticModelId = computed(() =>
  selectedModelIdForDiagnostics(featureConfig.value)
);
const selectedDiagnosticReasons = computed(() =>
  localizedDiagnosticReasons(featureConfig.value, t)
);

const handleModelChange = ({ feature, model }) => {
  emit('change', { feature, model });
};
</script>

<template>
  <div
    class="grid gap-3 p-4 rounded-xl border border-n-weak bg-n-solid-1"
    :class="{ 'opacity-60 pointer-events-none relative': !isAllowed }"
  >
    <div
      class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"
    >
      <div class="flex-1 min-w-0">
        <h4 class="text-sm font-medium text-n-slate-12">
          {{ title }}
        </h4>
        <p class="text-sm text-n-slate-11 mt-0.5">{{ description }}</p>
        <div
          v-if="shouldShowSelectedDiagnostics"
          data-test="selected-model-diagnostics"
          class="mt-3 rounded-lg border border-n-amber-5 bg-n-amber-2 px-3 py-2 text-xs text-n-amber-12"
        >
          <div class="font-medium">
            {{
              t('CAPTAIN_SETTINGS.MODEL_CONFIG.DIAGNOSTICS.TITLE', {
                model: selectedDiagnosticModelId,
              })
            }}
          </div>
          <ul class="mt-1 list-disc space-y-0.5 pl-4">
            <li v-for="reason in selectedDiagnosticReasons" :key="reason">
              {{ reason }}
            </li>
          </ul>
        </div>
      </div>
      <ModelDropdown
        v-if="isAllowed && hasAvailableModels"
        :feature-key="featureKey"
        :feature-title="title"
        :models="availableModels"
        @change="handleModelChange"
      />
      <div
        v-else-if="isAllowed"
        class="text-xs text-n-amber-11 bg-n-amber-3 border border-n-amber-5 rounded-lg px-3 py-2 max-w-72"
      >
        {{ t('CAPTAIN_SETTINGS.MODEL_CONFIG.NO_COMPATIBLE_MODELS') }}
      </div>
    </div>

    <div v-if="showControls && $slots.controls">
      <slot name="controls" />
    </div>
  </div>
</template>
