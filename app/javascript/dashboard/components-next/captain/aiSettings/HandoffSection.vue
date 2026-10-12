<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import OutcomeReasonSection from 'dashboard/routes/dashboard/captain/assistants/outcomes/OutcomeReasonSection.vue';
import {
  MAX_REASONS_PER_LIST,
  createCustomReason,
  insertReason,
  isBuiltInReason,
} from 'dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder';
import StatusMessageToggle from './StatusMessageToggle.vue';

// «Передача и завершение»: reason lists, the two status messages and the two
// workspace switches. Every part is its own block; nothing is nested.
const props = defineProps({
  errors: { type: Object, default: () => ({}) },
  showErrors: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const REASON_LISTS = [
  {
    key: 'handoff_reasons',
    type: 'handoff',
    titleKey: 'CAPTAIN.AI_SETTINGS.HANDOFF.HANDOFF_REASONS',
    descriptionKey: 'CAPTAIN.AI_SETTINGS.HANDOFF.HANDOFF_REASONS_DESCRIPTION',
  },
  {
    key: 'completion_reasons',
    type: 'completion',
    titleKey: 'CAPTAIN.AI_SETTINGS.HANDOFF.COMPLETION_REASONS',
    descriptionKey:
      'CAPTAIN.AI_SETTINGS.HANDOFF.COMPLETION_REASONS_DESCRIPTION',
  },
];

const STATUS_MESSAGES = [
  {
    key: 'handoff_message',
    kind: 'handoff',
    titleKey: 'CAPTAIN.AI_SETTINGS.HANDOFF.HANDOFF_MESSAGE',
    descriptionKey: 'CAPTAIN.AI_SETTINGS.HANDOFF.HANDOFF_MESSAGE_DESCRIPTION',
  },
  {
    key: 'resolution_message',
    kind: 'resolution',
    titleKey: 'CAPTAIN.AI_SETTINGS.HANDOFF.RESOLUTION_MESSAGE',
    descriptionKey:
      'CAPTAIN.AI_SETTINGS.HANDOFF.RESOLUTION_MESSAGE_DESCRIPTION',
  },
];

const switchRows = computed(() => [
  {
    key: 'auto_completion_enabled',
    title: t('CAPTAIN.AI_SETTINGS.HANDOFF.AUTO_COMPLETION'),
    description: t('CAPTAIN.AI_SETTINGS.HANDOFF.AUTO_COMPLETION_DESCRIPTION'),
  },
  {
    key: 'auto_reply_on_last_incoming',
    title: t('CAPTAIN.AI_SETTINGS.HANDOFF.REPLY_ON_RETURN'),
    description: t('CAPTAIN.AI_SETTINGS.HANDOFF.REPLY_ON_RETURN_DESCRIPTION'),
  },
]);

const updateField = (key, value) => {
  model.value = { ...model.value, [key]: value };
};

const reasonsOf = key =>
  Array.isArray(model.value?.[key]) ? model.value[key] : [];

const addReason = list => {
  const reasons = reasonsOf(list.key);
  if (props.disabled || reasons.length >= MAX_REASONS_PER_LIST) return;
  updateField(list.key, insertReason(reasons, createCustomReason(list.type)));
};

const removeReason = (list, reasonId) => {
  const reasons = reasonsOf(list.key);
  const reason = reasons.find(item => item.id === reasonId);
  if (props.disabled || !reason || isBuiltInReason(reason)) return;
  updateField(
    list.key,
    reasons.filter(item => item.id !== reasonId)
  );
};
</script>

<template>
  <section
    id="handoff"
    data-testid="ai-settings-handoff"
    class="flex scroll-mt-4 flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h2 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AI_SETTINGS.HANDOFF.TITLE') }}
      </h2>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.HANDOFF.DESCRIPTION') }}
      </p>
    </header>

    <OutcomeReasonSection
      v-for="list in REASON_LISTS"
      :key="list.key"
      :reasons="reasonsOf(list.key)"
      :type="list.key"
      :title="t(list.titleKey)"
      :description="t(list.descriptionKey)"
      :max-reasons="MAX_REASONS_PER_LIST"
      :show-errors="showErrors"
      :error="errors[list.key] || ''"
      :disabled="disabled"
      @add="addReason(list)"
      @remove="reasonId => removeReason(list, reasonId)"
    />

    <StatusMessageToggle
      v-for="message in STATUS_MESSAGES"
      :key="message.key"
      :model-value="model[message.key]"
      :kind="message.kind"
      :title="t(message.titleKey)"
      :description="t(message.descriptionKey)"
      :show-errors="showErrors"
      :error="errors[message.key] || ''"
      :instruction-error="errors[`${message.key}_instruction`] || ''"
      :disabled="disabled"
      @update:model-value="updateField(message.key, $event)"
    />

    <div
      data-testid="handoff-switches"
      class="flex flex-col divide-y divide-n-weak rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
    >
      <div
        v-for="row in switchRows"
        :key="row.key"
        :data-testid="`handoff-${row.key}`"
        class="flex flex-col gap-1 px-4 py-3"
      >
        <div class="flex items-center justify-between gap-3">
          <span class="min-w-0 text-heading-3 text-n-slate-12">
            {{ row.title }}
          </span>
          <Switch
            :model-value="model[row.key] === true"
            :disabled="disabled"
            :aria-label="row.title"
            @update:model-value="updateField(row.key, $event)"
          />
        </div>
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ row.description }}
        </p>
        <p
          v-if="errors[row.key]"
          role="alert"
          class="mb-0 text-body-main text-n-ruby-11"
        >
          {{ errors[row.key] }}
        </p>
      </div>
    </div>
  </section>
</template>
