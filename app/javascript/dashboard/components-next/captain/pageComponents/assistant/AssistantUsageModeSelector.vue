<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

defineProps({
  modelValue: {
    type: String,
    default: 'external_agent',
  },
});

const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();

const options = computed(() => [
  {
    value: 'external_agent',
    badgeClass: 'bg-n-brand/10 text-n-brand',
    badgeLabel: t(
      'CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.EXTERNAL_AGENT.BADGE'
    ),
    title: t('CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.EXTERNAL_AGENT.TITLE'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.EXTERNAL_AGENT.DESCRIPTION'
    ),
  },
  {
    value: 'internal_assistant',
    badgeClass: 'bg-n-alpha-2 text-n-slate-11',
    badgeLabel: t(
      'CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.INTERNAL_ASSISTANT.BADGE'
    ),
    title: t(
      'CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.INTERNAL_ASSISTANT.TITLE'
    ),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.OPTIONS.INTERNAL_ASSISTANT.DESCRIPTION'
    ),
  },
]);

const updateValue = value => {
  emit('update:modelValue', value);
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <div class="flex flex-col gap-1">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.TITLE') }}
      </h3>
      <p class="text-sm text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.DESCRIPTION') }}
      </p>
    </div>

    <div class="grid gap-3 md:grid-cols-2">
      <button
        v-for="option in options"
        :key="option.value"
        type="button"
        class="rounded-2xl border p-4 text-left transition-colors"
        :class="
          modelValue === option.value
            ? 'border-n-brand bg-n-brand/5'
            : 'border-n-weak bg-n-solid-1 hover:border-n-slate-6'
        "
        @click="updateValue(option.value)"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="flex flex-col gap-1">
            <h4 class="text-sm font-medium text-n-slate-12">
              {{ option.title }}
            </h4>
            <p class="text-sm text-n-slate-11">
              {{ option.description }}
            </p>
          </div>
          <span
            class="inline-flex shrink-0 rounded-full px-2 py-1 text-xs font-medium"
            :class="option.badgeClass"
          >
            {{ option.badgeLabel }}
          </span>
        </div>
      </button>
    </div>

    <p
      v-if="modelValue === 'internal_assistant'"
      class="rounded-xl border border-n-weak bg-n-alpha-1 px-3 py-2 text-sm text-n-slate-11"
    >
      {{ t('CAPTAIN.ASSISTANTS.FORM.USAGE_MODE.INTERNAL_ASSISTANT_HINT') }}
    </p>
  </div>
</template>
