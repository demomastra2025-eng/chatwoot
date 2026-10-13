<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import {
  CUSTOM_RULE_LIMITS,
  ruleActionsFor,
  validateCustomRules,
} from 'dashboard/helper/captainAiSettings';

// One direction of the workspace custom safety rules. The model is the whole
// rule list of both directions (the limit of 20 rules is shared), this list
// shows and edits only the rules of `direction`, in their priority order.
const props = defineProps({
  direction: {
    type: String,
    required: true,
    validator: value => ['inbound', 'outbound'].includes(value),
  },
  title: { type: String, required: true },
  description: { type: String, default: '' },
  // Show validation errors (the page tried to save).
  showErrors: { type: Boolean, default: false },
  // Server errors by rule id: { [ruleId]: { name, instruction, ... } }.
  serverErrors: { type: Object, default: () => ({}) },
  // A server error for the whole list.
  listError: { type: String, default: '' },
  disabled: { type: Boolean, default: false },
});

const model = defineModel({ type: Array, default: () => [] });

const { t } = useI18n();

const key = 'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS';
const LEGACY_DIRECTION_KEYS = { inbound: 'INPUT', outbound: 'OUTPUT' };
const RULE_TEXT_FIELDS = ['name', 'instruction', 'message'];

const validationAttempted = ref(false);
const showValidation = computed(
  () => props.showErrors || validationAttempted.value
);

const rules = computed(() =>
  model.value.filter(rule => rule.direction === props.direction)
);
const isAtLimit = computed(
  () => model.value.length >= CUSTOM_RULE_LIMITS.maxRules
);
const actionOptions = computed(() =>
  ruleActionsFor(props.direction).map(action => ({
    value: action,
    label: t(`${key}.ACTIONS.${action.toUpperCase()}`),
  }))
);
const examplePlaceholder = computed(() =>
  t(`${key}.${LEGACY_DIRECTION_KEYS[props.direction]}.EXAMPLE`)
);

const updateRule = (id, changes) => {
  model.value = model.value.map(rule =>
    rule.id === id ? { ...rule, ...changes } : rule
  );
};

const updateAction = (rule, action) => {
  if (!ruleActionsFor(rule.direction).includes(action)) return;
  updateRule(rule.id, { action });
};

const newRuleId = () => {
  if (window.crypto?.randomUUID) return window.crypto.randomUUID();
  const random = Math.random().toString(36).slice(2, 10);
  return `rule-${Date.now().toString(36)}-${random}`;
};

const addRule = () => {
  if (props.disabled || isAtLimit.value) return;
  const rule = {
    id: newRuleId(),
    name: '',
    direction: props.direction,
    instruction: '',
    action: 'handoff',
    enabled: true,
    message: '',
  };
  const list = [...model.value];
  const lastIndex = list.findLastIndex(
    item => item.direction === props.direction
  );
  list.splice(lastIndex < 0 ? list.length : lastIndex + 1, 0, rule);
  model.value = list;
};

const removeRule = id => {
  if (props.disabled) return;
  model.value = model.value.filter(rule => rule.id !== id);
};

// Priority is the order inside one direction; the other direction keeps its
// positions in the shared list.
const moveRule = (rule, offset) => {
  const position = rules.value.findIndex(item => item.id === rule.id);
  const target = rules.value[position + offset];
  if (props.disabled || !target) return;
  const list = [...model.value];
  const fromIndex = list.findIndex(item => item.id === rule.id);
  const toIndex = list.findIndex(item => item.id === target.id);
  [list[fromIndex], list[toIndex]] = [list[toIndex], list[fromIndex]];
  model.value = list;
};

const validation = computed(() => validateCustomRules(model.value));

const fieldError = (rule, field) => {
  if (showValidation.value && validation.value.fields[rule.id]?.[field]) {
    return t(`${key}.ERRORS.${field.toUpperCase()}`);
  }
  return props.serverErrors?.[rule.id]?.[field] || '';
};

const ruleError = rule => {
  const errors = props.serverErrors?.[rule.id] || {};
  const field = Object.keys(errors).find(
    item => !RULE_TEXT_FIELDS.includes(item)
  );
  return field ? errors[field] : '';
};

const listErrorMessage = computed(() => {
  if (showValidation.value) {
    const { tooMany, invalidRuleIds } = validation.value;
    const ids = new Set(rules.value.map(rule => rule.id));
    if (tooMany || invalidRuleIds.some(id => ids.has(id))) {
      return t(`${key}.ERRORS.RULES`);
    }
  }
  return props.listError;
});

const validate = () => {
  validationAttempted.value = true;
  return validation.value.valid;
};

defineExpose({ validate });
</script>

<template>
  <section
    :data-testid="`custom-rules-${direction}`"
    class="flex flex-col gap-4"
  >
    <header class="flex flex-col gap-1">
      <h3 class="mb-0 text-heading-3 text-n-slate-12">{{ title }}</h3>
      <p v-if="description" class="mb-0 text-body-main text-n-slate-11">
        {{ description }}
      </p>
    </header>

    <p
      v-if="listErrorMessage"
      role="alert"
      class="mb-0 text-body-main text-n-ruby-11"
    >
      {{ listErrorMessage }}
    </p>

    <p v-if="!rules.length" class="mb-0 text-body-main text-n-slate-11">
      {{ t(`${key}.EMPTY`) }}
    </p>
    <ol v-else class="m-0 flex list-none flex-col gap-4 p-0">
      <li
        v-for="(rule, index) in rules"
        :key="rule.id"
        :data-testid="`custom-rule-${rule.id}`"
      >
        <CardLayout>
          <div class="flex flex-wrap items-center justify-between gap-3">
            <span class="text-heading-3 text-n-slate-12">
              {{ t(`${key}.PRIORITY`, { position: index + 1 }) }}
            </span>
            <div class="flex items-center gap-3">
              <div class="flex items-center gap-1">
                <Button
                  icon="i-lucide-arrow-up"
                  color="slate"
                  variant="ghost"
                  size="xs"
                  :disabled="disabled || index === 0"
                  :aria-label="t(`${key}.MOVE_UP`)"
                  :data-testid="`custom-rule-up-${rule.id}`"
                  @click="moveRule(rule, -1)"
                />
                <Button
                  icon="i-lucide-arrow-down"
                  color="slate"
                  variant="ghost"
                  size="xs"
                  :disabled="disabled || index === rules.length - 1"
                  :aria-label="t(`${key}.MOVE_DOWN`)"
                  :data-testid="`custom-rule-down-${rule.id}`"
                  @click="moveRule(rule, 1)"
                />
                <Button
                  icon="i-lucide-trash-2"
                  color="ruby"
                  variant="ghost"
                  size="xs"
                  :disabled="disabled"
                  :aria-label="t(`${key}.DELETE`)"
                  :data-testid="`custom-rule-delete-${rule.id}`"
                  @click="removeRule(rule.id)"
                />
              </div>
              <Switch
                :model-value="rule.enabled === true"
                :disabled="disabled"
                :aria-label="t(`${key}.ACTIVE`)"
                @update:model-value="updateRule(rule.id, { enabled: $event })"
              />
            </div>
          </div>
          <Input
            :id="`custom-rule-${rule.id}-name`"
            :model-value="rule.name"
            :label="t(`${key}.NAME`)"
            :placeholder="t(`${key}.NAME_PLACEHOLDER`)"
            :maxlength="CUSTOM_RULE_LIMITS.name"
            :disabled="disabled"
            :message="fieldError(rule, 'name')"
            :message-type="fieldError(rule, 'name') ? 'error' : 'info'"
            @update:model-value="updateRule(rule.id, { name: $event })"
          />
          <TextArea
            :id="`custom-rule-${rule.id}-instruction`"
            :model-value="rule.instruction"
            :label="t(`${key}.INSTRUCTION`)"
            :placeholder="examplePlaceholder"
            :max-length="CUSTOM_RULE_LIMITS.instruction"
            :disabled="disabled"
            :message="fieldError(rule, 'instruction')"
            :message-type="fieldError(rule, 'instruction') ? 'error' : 'info'"
            auto-height
            show-character-count
            @update:model-value="updateRule(rule.id, { instruction: $event })"
          />
          <div class="flex flex-col gap-1">
            <label
              :for="`custom-rule-${rule.id}-action`"
              class="mb-0 text-heading-3 text-n-slate-12"
            >
              {{ t(`${key}.ACTION`) }}
            </label>
            <Select
              :id="`custom-rule-${rule.id}-action`"
              :model-value="rule.action"
              :options="actionOptions"
              :disabled="disabled"
              class="w-full"
              @update:model-value="updateAction(rule, $event)"
            />
          </div>
          <TextArea
            :id="`custom-rule-${rule.id}-message`"
            :model-value="rule.message || ''"
            :label="t(`${key}.MESSAGE`)"
            :placeholder="t(`${key}.MESSAGE_PLACEHOLDER`)"
            :max-length="CUSTOM_RULE_LIMITS.message"
            :disabled="disabled"
            :message="fieldError(rule, 'message')"
            :message-type="fieldError(rule, 'message') ? 'error' : 'info'"
            auto-height
            show-character-count
            @update:model-value="updateRule(rule.id, { message: $event })"
          />
          <p
            v-if="ruleError(rule)"
            role="alert"
            class="mb-0 text-body-main text-n-ruby-11"
          >
            {{ ruleError(rule) }}
          </p>
        </CardLayout>
      </li>
    </ol>

    <div class="flex flex-wrap items-center gap-3">
      <Button
        :label="t('CAPTAIN.AI_SETTINGS.SAFETY.ADD_RULE')"
        color="slate"
        variant="faded"
        size="sm"
        :disabled="disabled || isAtLimit"
        :data-testid="`custom-rule-add-${direction}`"
        @click="addRule"
      />
      <p v-if="isAtLimit" class="mb-0 text-body-main text-n-slate-11">
        {{
          t('CAPTAIN.AI_SETTINGS.SAFETY.RULES_LIMIT', {
            count: CUSTOM_RULE_LIMITS.maxRules,
          })
        }}
      </p>
    </div>
  </section>
</template>
