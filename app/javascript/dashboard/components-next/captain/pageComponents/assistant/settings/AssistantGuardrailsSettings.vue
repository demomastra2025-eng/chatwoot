<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  modelValue: { type: Array, default: () => [] },
});
const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const validationAttempted = ref(false);
const key = 'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS';
const maxRules = 20;
const groups = computed(() =>
  ['input', 'output'].map(direction => ({
    direction,
    rules: props.modelValue.filter(rule => rule.direction === direction),
  }))
);
const actionOptions = direction => [
  { value: 'handoff', label: t(`${key}.ACTIONS.HANDOFF`) },
  ...(direction === 'output'
    ? [{ value: 'rewrite', label: t(`${key}.ACTIONS.REWRITE`) }]
    : []),
];
// Existing service-level block rules have the same public handoff effect.
// Keep their stored value until the user explicitly changes the action.
const displayAction = rule =>
  rule.action === 'block' ? 'handoff' : rule.action;

const updateRule = (id, changes) => {
  emit(
    'update:modelValue',
    props.modelValue.map(rule =>
      rule.id === id ? { ...rule, ...changes } : rule
    )
  );
};
const updateAction = (rule, action) => {
  if (!actionOptions(rule.direction).some(option => option.value === action)) {
    return;
  }
  updateRule(rule.id, { action });
};
const addRule = direction => {
  if (props.modelValue.length >= maxRules) return;
  const rule = {
    id: window.crypto.randomUUID(),
    name: '',
    direction,
    instruction: '',
    action: 'handoff',
    enabled: true,
  };
  const rules = [...props.modelValue];
  const lastIndex = rules.findLastIndex(item => item.direction === direction);
  rules.splice(lastIndex < 0 ? rules.length : lastIndex + 1, 0, rule);
  emit('update:modelValue', rules);
};
const removeRule = id => {
  emit(
    'update:modelValue',
    props.modelValue.filter(rule => rule.id !== id)
  );
};
const moveRule = (rule, offset) => {
  const group = props.modelValue.filter(
    item => item.direction === rule.direction
  );
  const position = group.findIndex(item => item.id === rule.id);
  const target = group[position + offset];
  if (!target) return;
  const rules = [...props.modelValue];
  const fromIndex = rules.findIndex(item => item.id === rule.id);
  const toIndex = rules.findIndex(item => item.id === target.id);
  [rules[fromIndex], rules[toIndex]] = [rules[toIndex], rules[fromIndex]];
  emit('update:modelValue', rules);
};

const validText = (value, limit, required = true) =>
  (value === undefined && !required) ||
  (typeof value === 'string' &&
    (!required || value.trim().length > 0) &&
    value.length <= limit);
const validMetadata = rule =>
  typeof rule.id === 'string' &&
  /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(rule.id) &&
  rule.id !== 'none' &&
  ['input', 'output'].includes(rule.direction) &&
  [
    'handoff',
    'block',
    ...(rule.direction === 'output' ? ['rewrite'] : []),
  ].includes(rule.action) &&
  typeof rule.enabled === 'boolean';
const fieldError = (rule, field) => {
  if (!validationAttempted.value) return '';
  const limit = field === 'name' ? 120 : 2000;
  return validText(rule[field], limit, field !== 'message')
    ? ''
    : t(`${key}.ERRORS.${field.toUpperCase()}`);
};
const listError = computed(() => {
  if (!validationAttempted.value) return '';
  const ids = new Set(props.modelValue.map(rule => rule.id));
  return props.modelValue.length <= maxRules &&
    ids.size === props.modelValue.length &&
    props.modelValue.every(validMetadata)
    ? ''
    : t(`${key}.ERRORS.RULES`);
});
const validate = () => {
  validationAttempted.value = true;
  return (
    !listError.value &&
    props.modelValue.every(
      rule =>
        validText(rule.name, 120) &&
        validText(rule.instruction, 2000) &&
        validText(rule.message, 2000, false)
    )
  );
};
defineExpose({ validate });
</script>

<template>
  <section class="border-t border-n-weak pt-5" data-test="custom-guardrails">
    <h4 class="text-sm font-medium text-n-slate-12">{{ t(`${key}.TITLE`) }}</h4>
    <p class="mt-1 text-xs text-n-slate-11">{{ t(`${key}.DESCRIPTION`) }}</p>
    <p v-if="listError" class="mt-2 text-sm text-n-ruby-9" role="alert">
      {{ listError }}
    </p>
    <section
      v-for="group in groups"
      :key="group.direction"
      class="mt-5"
      :data-test="`guardrail-group-${group.direction}`"
    >
      <h5 class="text-sm font-medium text-n-slate-12">
        {{ t(`${key}.${group.direction.toUpperCase()}.TITLE`) }}
      </h5>
      <p class="mt-1 text-xs text-n-slate-11">
        {{ t(`${key}.${group.direction.toUpperCase()}.DESCRIPTION`) }}
      </p>
      <p v-if="!group.rules.length" class="my-3 text-sm text-n-slate-11">
        {{ t(`${key}.EMPTY`) }}
      </p>
      <ol v-else class="m-0 list-none p-0">
        <li
          v-for="(rule, index) in group.rules"
          :key="rule.id"
          class="flex flex-col gap-3 border-b border-n-weak py-4"
          :data-test="`guardrail-${rule.id}`"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <span class="text-sm text-n-slate-11">
              {{ t(`${key}.PRIORITY`, { position: index + 1 }) }}
            </span>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              {{ t(`${key}.ACTIVE`) }}
              <Switch
                :model-value="rule.enabled === true"
                :aria-label="t(`${key}.ACTIVE`)"
                @update:model-value="updateRule(rule.id, { enabled: $event })"
              />
            </label>
          </div>
          <Input
            :id="`guardrail-${rule.id}-name`"
            :model-value="rule.name"
            :label="t(`${key}.NAME`)"
            :placeholder="t(`${key}.NAME_PLACEHOLDER`)"
            :maxlength="120"
            :message="fieldError(rule, 'name')"
            :message-type="fieldError(rule, 'name') ? 'error' : 'info'"
            @update:model-value="updateRule(rule.id, { name: $event })"
          />
          <TextArea
            :id="`guardrail-${rule.id}-instruction`"
            :model-value="rule.instruction"
            :label="t(`${key}.INSTRUCTION`)"
            :placeholder="t(`${key}.${group.direction.toUpperCase()}.EXAMPLE`)"
            :max-length="2000"
            :message="fieldError(rule, 'instruction')"
            :message-type="fieldError(rule, 'instruction') ? 'error' : 'info'"
            auto-height
            show-character-count
            @update:model-value="updateRule(rule.id, { instruction: $event })"
          />
          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ t(`${key}.ACTION`) }}
            <Select
              :model-value="displayAction(rule)"
              :options="actionOptions(group.direction)"
              class="w-full"
              @update:model-value="updateAction(rule, $event)"
            />
          </label>
          <TextArea
            :id="`guardrail-${rule.id}-message`"
            :model-value="rule.message || ''"
            :label="t(`${key}.MESSAGE`)"
            :placeholder="t(`${key}.MESSAGE_PLACEHOLDER`)"
            :max-length="2000"
            :message="fieldError(rule, 'message')"
            :message-type="fieldError(rule, 'message') ? 'error' : 'info'"
            auto-height
            show-character-count
            @update:model-value="updateRule(rule.id, { message: $event })"
          />
          <div class="flex flex-wrap gap-2">
            <Button
              :label="t(`${key}.MOVE_UP`)"
              :disabled="index === 0"
              :data-test="`guardrail-up-${rule.id}`"
              color="slate"
              variant="ghost"
              size="sm"
              @click="moveRule(rule, -1)"
            />
            <Button
              :label="t(`${key}.MOVE_DOWN`)"
              :disabled="index === group.rules.length - 1"
              :data-test="`guardrail-down-${rule.id}`"
              color="slate"
              variant="ghost"
              size="sm"
              @click="moveRule(rule, 1)"
            />
            <Button
              :label="t(`${key}.DELETE`)"
              :data-test="`guardrail-delete-${rule.id}`"
              color="ruby"
              variant="ghost"
              size="sm"
              @click="removeRule(rule.id)"
            />
          </div>
        </li>
      </ol>
      <Button
        :label="t(`${key}.ADD`)"
        :disabled="modelValue.length >= maxRules"
        :data-test="`guardrail-add-${group.direction}`"
        class="mt-3"
        color="slate"
        variant="ghost"
        size="sm"
        @click="addRule(group.direction)"
      />
    </section>
    <p
      v-if="modelValue.length >= maxRules"
      class="mt-3 text-xs text-n-slate-11"
    >
      {{ t(`${key}.LIMIT`, { count: maxRules }) }}
    </p>
  </section>
</template>
