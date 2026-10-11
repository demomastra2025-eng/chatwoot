<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';

// «Скорость ответа»: how long agents wait to join consecutive customer
// messages into one reply.
const props = defineProps({
  // `collapse_window` holds a validation or server message for the field.
  errors: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const error = computed(() => props.errors.collapse_window || '');

const updateSeconds = value => {
  model.value = { ...model.value, message_collapse_window_seconds: value };
};
</script>

<template>
  <section
    id="speed"
    data-testid="ai-settings-speed"
    class="flex scroll-mt-4 flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h2 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AI_SETTINGS.SPEED.TITLE') }}
      </h2>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.SPEED.DESCRIPTION') }}
      </p>
    </header>

    <div
      class="flex flex-col gap-1 rounded-xl bg-n-solid-1 p-4 outline outline-1 -outline-offset-1 outline-n-weak"
    >
      <Input
        id="ai-settings-collapse-window"
        :model-value="model.message_collapse_window_seconds"
        type="number"
        min="0"
        step="1"
        inputmode="numeric"
        class="w-full sm:max-w-48"
        :label="t('CAPTAIN.AI_SETTINGS.SPEED.COLLAPSE_WINDOW')"
        :disabled="disabled"
        :message="error"
        :message-type="error ? 'error' : 'info'"
        @update:model-value="updateSeconds"
      />
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.SPEED.COLLAPSE_HINT') }}
      </p>
    </div>
  </section>
</template>
