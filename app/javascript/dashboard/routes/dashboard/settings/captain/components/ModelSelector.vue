<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';
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
});

const emit = defineEmits(['change']);
const { t } = useI18n();
const captainConfigStore = useCaptainConfigStore();

const availableModels = computed(() =>
  captainConfigStore.getModelsForFeature(props.featureKey)
);
const hasAvailableModels = computed(() => availableModels.value.length > 0);

const handleModelChange = ({ feature, model }) => {
  emit('change', { feature, model });
};
</script>

<template>
  <div
    class="flex items-center justify-between gap-4 p-4 rounded-xl border border-n-weak bg-n-solid-1"
    :class="{ 'opacity-60 pointer-events-none relative': !isAllowed }"
  >
    <div class="flex-1 min-w-0">
      <h4 class="text-sm font-medium text-n-slate-12">
        {{ title }}
      </h4>
      <p class="text-sm text-n-slate-11 mt-0.5">{{ description }}</p>
    </div>
    <ModelDropdown
      v-if="isAllowed && hasAvailableModels"
      :feature-key="featureKey"
      @change="handleModelChange"
    />
    <div
      v-else-if="isAllowed"
      class="text-xs text-n-amber-11 bg-n-amber-3 border border-n-amber-5 rounded-lg px-3 py-2 max-w-72"
    >
      {{ t('CAPTAIN_SETTINGS.MODEL_CONFIG.NO_COMPATIBLE_MODELS') }}
    </div>
  </div>
</template>
