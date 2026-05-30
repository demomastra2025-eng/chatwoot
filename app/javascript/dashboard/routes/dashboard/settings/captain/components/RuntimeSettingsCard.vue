<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { storeToRefs } from 'pinia';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SingleSelect from 'dashboard/components-next/filter/inputs/SingleSelect.vue';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

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
  moderationTitle: {
    type: String,
    required: true,
  },
  moderationDescription: {
    type: String,
    required: true,
  },
  thinkingTitle: {
    type: String,
    required: true,
  },
  thinkingDescription: {
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
const { runtime } = storeToRefs(captainConfigStore);

const moderationKey = computed(() => `${props.featureKey}_moderation`);
const thinkingKey = computed(() => `${props.featureKey}_thinking_effort`);

const moderationEnabled = ref(false);
const thinkingOptions = computed(() => [
  { id: 'none', name: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.NONE') },
  { id: 'low', name: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.LOW') },
  { id: 'medium', name: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.MEDIUM') },
  { id: 'high', name: t('CAPTAIN_SETTINGS.RUNTIME.THINKING.OPTIONS.HIGH') },
]);
const selectedThinking = ref(null);

watch(
  runtime,
  newRuntime => {
    moderationEnabled.value = !!newRuntime[moderationKey.value];
    selectedThinking.value =
      thinkingOptions.value.find(
        option => option.id === (newRuntime[thinkingKey.value] || 'none')
      ) || thinkingOptions.value[0];
  },
  { immediate: true, deep: true }
);

const handleModerationChange = () => {
  emit('change', {
    [moderationKey.value]: moderationEnabled.value,
  });
};

const handleThinkingChange = option => {
  emit('change', {
    [thinkingKey.value]: option?.id || 'none',
  });
};
</script>

<template>
  <div
    class="rounded-xl border border-n-weak bg-n-solid-1 p-4 grid gap-3"
    :class="{ 'opacity-60 pointer-events-none': !isAllowed }"
  >
    <div>
      <h4 class="text-sm font-medium text-n-slate-12">{{ title }}</h4>
      <p class="text-sm text-n-slate-11 mt-0.5">{{ description }}</p>
    </div>

    <div class="grid gap-2 md:grid-cols-2">
      <div
        class="flex min-w-0 items-center justify-between gap-3 rounded-lg border border-n-weak bg-n-alpha-1 p-3"
      >
        <div class="min-w-0">
          <h5 class="text-xs font-medium text-n-slate-12">
            {{ moderationTitle }}
          </h5>
          <p class="text-xs text-n-slate-11 mt-0.5">
            {{ moderationDescription }}
          </p>
        </div>
        <Switch
          v-if="isAllowed"
          v-model="moderationEnabled"
          @change="handleModerationChange"
        />
      </div>

      <div
        class="flex min-w-0 items-center justify-between gap-3 rounded-lg border border-n-weak bg-n-alpha-1 p-3"
      >
        <div class="min-w-0">
          <h5 class="text-xs font-medium text-n-slate-12">
            {{ thinkingTitle }}
          </h5>
          <p class="text-xs text-n-slate-11 mt-0.5">
            {{ thinkingDescription }}
          </p>
        </div>
        <SingleSelect
          v-if="isAllowed"
          v-model="selectedThinking"
          :options="thinkingOptions"
          disable-search
          variant="faded"
          class="min-w-36"
          @update:model-value="handleThinkingChange"
        />
      </div>
    </div>
  </div>
</template>
