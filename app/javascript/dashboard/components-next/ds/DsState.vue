<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Button from 'dashboard/components-next/button/Button.vue';

// Empty / loading / error placeholder for a card, table or chart body.
const props = defineProps({
  state: {
    type: String,
    default: 'empty',
    validator: value => ['empty', 'loading', 'error'].includes(value),
  },
  title: { type: String, default: '' },
  // null: the default text for the state, '': no description
  description: { type: String, default: null },
  retryable: { type: Boolean, default: true },
  compact: { type: Boolean, default: false },
});

const emit = defineEmits(['retry']);

const { t } = useI18n();

const defaults = computed(
  () =>
    ({
      empty: {
        title: t('DESIGN_SYSTEM.STATE.EMPTY_TITLE'),
        description: t('DESIGN_SYSTEM.STATE.EMPTY_DESCRIPTION'),
      },
      loading: { title: t('DESIGN_SYSTEM.STATE.LOADING'), description: '' },
      error: {
        title: t('DESIGN_SYSTEM.STATE.ERROR_TITLE'),
        description: t('DESIGN_SYSTEM.STATE.ERROR_DESCRIPTION'),
      },
    })[props.state]
);

const heading = computed(() => props.title || defaults.value.title);
const text = computed(() =>
  props.description !== null ? props.description : defaults.value.description
);
</script>

<template>
  <div
    class="flex flex-col items-center justify-center gap-1.5 px-5 text-center"
    :class="compact ? 'py-6' : 'py-10'"
    :role="state === 'error' ? 'alert' : 'status'"
    :aria-busy="state === 'loading' || undefined"
    :data-state="state"
  >
    <Spinner v-if="state === 'loading'" :size="20" class="text-n-slate-11" />
    <span
      v-else-if="state === 'error'"
      class="inline-flex items-center gap-1.5 text-sm font-medium text-n-slate-12"
    >
      <span
        class="inline-block size-[7px] rounded-full bg-n-status-bad"
        aria-hidden="true"
      />
      {{ heading }}
    </span>
    <span
      v-if="state !== 'error'"
      class="text-sm"
      :class="
        state === 'loading' ? 'text-n-slate-11' : 'font-medium text-n-slate-12'
      "
    >
      {{ heading }}
    </span>
    <span v-if="text" class="max-w-sm text-ds-caption text-n-slate-11">
      {{ text }}
    </span>
    <Button
      v-if="state === 'error' && retryable"
      class="mt-2"
      size="sm"
      variant="outline"
      color="slate"
      :label="t('DESIGN_SYSTEM.STATE.RETRY')"
      @click="emit('retry')"
    />
  </div>
</template>
