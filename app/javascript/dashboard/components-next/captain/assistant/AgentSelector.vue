<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { normalizeAssistantIds } from './assistantAccess';

const props = defineProps({
  modelValue: { type: Array, default: () => [] },
  assistants: { type: Array, default: () => [] },
  disabled: { type: Boolean, default: false },
  label: { type: String, default: '' },
});
const emit = defineEmits(['update:modelValue']);
const { t } = useI18n();
const selectedIds = computed(() => normalizeAssistantIds(props.modelValue));
const toggleAssistant = (id, checked) => {
  const value = Number(id);
  emit(
    'update:modelValue',
    checked
      ? normalizeAssistantIds([...selectedIds.value, value])
      : selectedIds.value.filter(item => item !== value)
  );
};
</script>

<template>
  <fieldset class="m-0 min-w-0 border-0 p-0" :disabled="disabled">
    <legend v-if="label" class="mb-2 text-sm font-medium text-n-slate-12">
      {{ label }}
    </legend>
    <div class="max-h-48 space-y-2 overflow-y-auto">
      <label
        v-for="assistant in assistants"
        :key="assistant.id"
        class="flex cursor-pointer items-center gap-2 text-sm text-n-slate-12"
      >
        <input
          type="checkbox"
          :value="assistant.id"
          :checked="selectedIds.includes(Number(assistant.id))"
          :disabled="disabled"
          @change="toggleAssistant(assistant.id, $event.target.checked)"
        />
        <span>{{ assistant.name }}</span>
      </label>
      <p v-if="!assistants.length" class="m-0 text-xs text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.ROUTING.NO_AGENTS') }}
      </p>
    </div>
  </fieldset>
</template>
