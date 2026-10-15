<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import { SAFETY_ACTIONS } from 'dashboard/helper/captainAiSettings';
import CustomRulesList from './CustomRulesList.vue';

// «Безопасность»: standard checks and the custom inbound/outbound rules that
// every agent of the workspace uses.
const props = defineProps({
  errors: { type: Object, default: () => ({}) },
  // Server errors of single rules: { [ruleId]: { field: message } }.
  ruleErrors: { type: Object, default: () => ({}) },
  showErrors: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Object, required: true });

const { t } = useI18n();

const ACTION_LABEL_KEYS = {
  block: 'CAPTAIN.ASSISTANTS.FORM.SAFETY_SETTINGS.BLOCK',
  flag: 'CAPTAIN.ASSISTANTS.FORM.SAFETY_SETTINGS.FLAG',
  off: 'CAPTAIN.AI_SETTINGS.SAFETY.OFF',
};

const actionOptions = computed(() =>
  SAFETY_ACTIONS.map(action => ({
    value: action,
    label: t(ACTION_LABEL_KEYS[action]),
  }))
);

const actionFields = computed(() => [
  {
    key: 'prompt_injection_action',
    label: t('CAPTAIN.AI_SETTINGS.SAFETY.INJECTION'),
    description: t('CAPTAIN.AI_SETTINGS.SAFETY.INJECTION_DESCRIPTION'),
  },
  {
    key: 'sensitive_info_action',
    label: t('CAPTAIN.AI_SETTINGS.SAFETY.SENSITIVE'),
    description: t('CAPTAIN.AI_SETTINGS.SAFETY.SENSITIVE_DESCRIPTION'),
  },
]);

const ruleLists = computed(() => [
  {
    direction: 'inbound',
    title: t('CAPTAIN.AI_SETTINGS.SAFETY.INBOUND'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.INPUT.DESCRIPTION'
    ),
  },
  {
    direction: 'outbound',
    title: t('CAPTAIN.AI_SETTINGS.SAFETY.OUTBOUND'),
    description: t(
      'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.OUTPUT.DESCRIPTION'
    ),
  },
]);

const update = (key, value) => {
  model.value = { ...model.value, [key]: value };
};

const updateAction = (key, value) => {
  if (!SAFETY_ACTIONS.includes(value)) return;
  update(key, value);
};

const customRules = computed({
  get: () =>
    Array.isArray(model.value?.custom_rules) ? model.value.custom_rules : [],
  set: value => update('custom_rules', value),
});

const moderationError = computed(() => props.errors.moderation_enabled || '');
</script>

<template>
  <section
    id="safety"
    data-testid="ai-settings-safety"
    class="flex scroll-mt-4 flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h2 class="mb-0 text-heading-2 text-n-slate-12">
        {{ t('CAPTAIN.AI_SETTINGS.SAFETY.TITLE') }}
      </h2>
      <p class="mb-0 text-body-main text-n-slate-11">
        {{ t('CAPTAIN.AI_SETTINGS.SAFETY.DESCRIPTION') }}
      </p>
    </header>

    <div class="flex flex-col gap-2">
      <div class="flex flex-col gap-1">
        <h3 class="mb-0 text-heading-3 text-n-slate-12">
          {{ t('CAPTAIN.AI_SETTINGS.SAFETY.STANDARD') }}
        </h3>
        <p class="mb-0 text-body-main text-n-slate-11">
          {{ t('CAPTAIN.ASSISTANTS.FORM.SAFETY_SETTINGS.DESCRIPTION') }}
        </p>
      </div>
      <div
        data-testid="safety-standard"
        class="flex flex-col gap-4 rounded-xl bg-n-solid-2 p-4 outline outline-1 -outline-offset-1 outline-n-weak"
      >
        <div class="flex flex-col gap-1">
          <div class="flex items-center justify-between gap-3">
            <span class="min-w-0 text-heading-3 text-n-slate-12">
              {{ t('CAPTAIN.AI_SETTINGS.SAFETY.MODERATION') }}
            </span>
            <Switch
              :model-value="model.moderation_enabled === true"
              :disabled="disabled"
              :aria-label="t('CAPTAIN.AI_SETTINGS.SAFETY.MODERATION')"
              data-testid="safety-moderation"
              @update:model-value="update('moderation_enabled', $event)"
            />
          </div>
          <p class="mb-0 text-body-main text-n-slate-11">
            {{ t('CAPTAIN.AI_SETTINGS.SAFETY.MODERATION_DESCRIPTION') }}
          </p>
          <p
            v-if="moderationError"
            role="alert"
            class="mb-0 text-body-main text-n-ruby-11"
          >
            {{ moderationError }}
          </p>
        </div>

        <div class="grid gap-4 border-t border-n-weak pt-4 sm:grid-cols-2">
          <div
            v-for="field in actionFields"
            :key="field.key"
            class="flex min-w-0 flex-col gap-1"
          >
            <label
              :for="`ai-settings-${field.key}`"
              class="mb-0 text-heading-3 text-n-slate-12"
            >
              {{ field.label }}
            </label>
            <Select
              :id="`ai-settings-${field.key}`"
              :model-value="model[field.key]"
              :options="actionOptions"
              :disabled="disabled"
              :error="errors[field.key] || ''"
              class="w-full"
              @update:model-value="updateAction(field.key, $event)"
            />
            <p class="mb-0 text-body-main text-n-slate-11">
              {{ field.description }}
            </p>
            <p
              v-if="errors[field.key]"
              role="alert"
              class="mb-0 text-body-main text-n-ruby-11"
            >
              {{ errors[field.key] }}
            </p>
          </div>
        </div>
      </div>
    </div>

    <CustomRulesList
      v-for="list in ruleLists"
      :key="list.direction"
      v-model="customRules"
      :direction="list.direction"
      :title="list.title"
      :description="list.description"
      :show-errors="showErrors"
      :server-errors="ruleErrors"
      :list-error="errors.custom_rules || ''"
      :disabled="disabled"
    />
  </section>
</template>
