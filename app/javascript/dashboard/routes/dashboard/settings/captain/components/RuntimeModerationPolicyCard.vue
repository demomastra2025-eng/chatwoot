<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { storeToRefs } from 'pinia';
import SingleSelect from 'dashboard/components-next/filter/inputs/SingleSelect.vue';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

defineProps({
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
const { runtime } = storeToRefs(captainConfigStore);

const failureModeOptions = computed(() => [
  {
    id: 'fail_open',
    name: t(
      'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.OPTIONS.FAIL_OPEN'
    ),
  },
  {
    id: 'fail_closed',
    name: t(
      'CAPTAIN_SETTINGS.RUNTIME.MODERATION_FAILURE_MODE.OPTIONS.FAIL_CLOSED'
    ),
  },
]);

const selectedFailureMode = ref(failureModeOptions.value[0]);

watch(
  runtime,
  newRuntime => {
    const activeMode = newRuntime.moderation_failure_mode || 'fail_open';
    selectedFailureMode.value =
      failureModeOptions.value.find(option => option.id === activeMode) ||
      failureModeOptions.value[0];
  },
  { immediate: true, deep: true }
);

const handleFailureModeChange = option => {
  emit('change', {
    moderation_failure_mode: option?.id || 'fail_open',
  });
};
</script>

<template>
  <div
    class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3 md:flex-row md:items-center md:justify-between"
    :class="{ 'opacity-60 pointer-events-none': !isAllowed }"
  >
    <div class="min-w-0">
      <h4 class="text-sm font-medium text-n-slate-12">{{ title }}</h4>
      <p class="text-sm text-n-slate-11 mt-0.5">{{ description }}</p>
    </div>

    <SingleSelect
      v-if="isAllowed"
      v-model="selectedFailureMode"
      :options="failureModeOptions"
      disable-search
      variant="faded"
      class="max-w-56"
      @update:model-value="handleFailureModeChange"
    />
  </div>
</template>
