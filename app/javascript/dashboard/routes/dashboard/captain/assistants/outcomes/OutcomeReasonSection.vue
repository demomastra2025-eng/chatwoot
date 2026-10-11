<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import {
  MAX_REASONS_PER_LIST,
  MAX_REASON_LABEL_LENGTH,
  isBuiltInReason,
  isReasonLocked,
} from './reasonOrder';

// One block with an editable outcome reason list. The handoff and the
// completion lists are both rendered by this component, so they cannot drift
// apart in markup, spacing or behaviour of the system ("Other") reason.
// The block is a single frame: rows are divided by lines, never framed.
const props = defineProps({
  type: { type: String, required: true },
  title: { type: String, required: true },
  description: { type: String, default: '' },
  maxReasons: { type: Number, default: MAX_REASONS_PER_LIST },
  // Highlights empty labels once the page tried to save.
  showErrors: { type: Boolean, default: false },
  // A message for the whole list (validation or a server error).
  error: { type: String, default: '' },
  disabled: { type: Boolean, default: false },
});

const emit = defineEmits(['add', 'remove']);

// Reasons are already ordered by the owner of the list (see reasonOrder.js).
// Rows edit the label and the enabled flag of the given reason objects.
const reasons = defineModel('reasons', { type: Array, default: () => [] });

const { t } = useI18n();

const isAtLimit = computed(() => reasons.value.length >= props.maxReasons);
const limitNote = computed(() =>
  t('CAPTAIN.AI_SETTINGS.HANDOFF.REASONS_LIMIT', { count: props.maxReasons })
);
const isInvalid = reason =>
  props.showErrors && !String(reason.label || '').trim();
</script>

<template>
  <section
    :data-testid="`outcome-section-${type}`"
    class="flex flex-col rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
  >
    <header class="flex flex-col gap-1 px-4 py-3">
      <h4 class="mb-0 text-heading-3 text-n-slate-12">
        {{ title }}
      </h4>
      <p v-if="description" class="mb-0 text-body-main text-n-slate-11">
        {{ description }}
      </p>
    </header>

    <ul
      v-if="reasons.length"
      class="m-0 flex list-none flex-col divide-y divide-n-weak border-t border-n-weak p-0"
    >
      <li
        v-for="reason in reasons"
        :key="reason.id"
        data-testid="outcome-reason-row"
        :data-reason-id="reason.id"
        class="flex items-center gap-3 px-4 py-2.5"
      >
        <span
          class="size-1.5 shrink-0 rounded-full"
          :class="isInvalid(reason) ? 'bg-n-ruby-9' : 'bg-n-slate-8'"
        />
        <input
          v-model="reason.label"
          :aria-label="title"
          :aria-invalid="isInvalid(reason) ? 'true' : undefined"
          :maxlength="MAX_REASON_LABEL_LENGTH"
          :disabled="disabled"
          class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-n-slate-12 outline-none"
          :class="
            isInvalid(reason)
              ? 'placeholder:text-n-ruby-9'
              : 'placeholder:text-n-slate-10'
          "
          :placeholder="t('CAPTAIN.ASSISTANTS.OUTCOMES.PLACEHOLDER')"
        />
        <Switch
          v-if="!isReasonLocked(reason)"
          v-model="reason.enabled"
          :disabled="disabled"
          :aria-label="t('CAPTAIN.ASSISTANTS.OUTCOMES.ACTIVE')"
        />
        <Button
          v-if="!isBuiltInReason(reason)"
          data-testid="outcome-remove"
          icon="i-lucide-trash-2"
          color="slate"
          variant="ghost"
          size="xs"
          :disabled="disabled"
          :aria-label="t('CAPTAIN.ASSISTANTS.OUTCOMES.REMOVE')"
          @click="emit('remove', reason.id)"
        />
        <span v-else class="size-6 shrink-0" aria-hidden="true" />
      </li>
    </ul>

    <footer
      data-testid="outcome-reasons-footer"
      class="flex flex-wrap items-center justify-between gap-3 border-t border-n-weak px-4 py-3"
    >
      <p
        v-if="error"
        role="alert"
        class="mb-0 min-w-0 text-body-main text-n-ruby-11"
      >
        {{ error }}
      </p>
      <p
        v-else-if="isAtLimit"
        class="mb-0 min-w-0 text-body-main text-n-slate-11"
      >
        {{ limitNote }}
      </p>
      <Button
        icon="i-lucide-plus"
        color="slate"
        variant="faded"
        size="sm"
        class="ms-auto"
        :label="t('CAPTAIN.ASSISTANTS.OUTCOMES.ADD')"
        :disabled="disabled || isAtLimit"
        :data-testid="`outcome-add-${type}`"
        @click="emit('add')"
      />
    </footer>
  </section>
</template>
