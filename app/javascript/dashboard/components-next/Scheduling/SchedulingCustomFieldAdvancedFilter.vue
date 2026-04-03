<script setup>
import { computed, nextTick, ref, watch } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import { useEventListener } from '@vueuse/core';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import SchedulingDateTimeField from './SchedulingDateTimeField.vue';

const props = defineProps({
  applyLabel: {
    type: String,
    default: '',
  },
  clearLabel: {
    type: String,
    default: '',
  },
  definition: {
    type: Object,
    required: true,
  },
  modelValue: {
    type: Object,
    default: null,
  },
  operatorOptions: {
    type: Array,
    default: () => [],
  },
  placeholder: {
    type: String,
    default: '',
  },
  summaryLabel: {
    type: String,
    default: '',
  },
  valuePlaceholder: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['update:modelValue']);

const VALUELESS_OPERATORS = ['is_not_present', 'is_present'];

const isOpen = ref(false);
const triggerRef = ref(null);
const dropdownStyle = ref({});
const teleportTarget = ref('body');
const draftOperator = ref('');
const draftValue = ref('');

const operatorRequiresValue = computed(
  () => !VALUELESS_OPERATORS.includes(draftOperator.value)
);
const isNumericField = computed(() =>
  ['number', 'currency', 'percent'].includes(props.definition?.fieldType)
);
const isDateField = computed(() => props.definition?.fieldType === 'date');
const isDateTimeField = computed(
  () => props.definition?.fieldType === 'datetime'
);
const buttonLabel = computed(() => props.summaryLabel || props.placeholder);

const syncDraftFromModel = () => {
  draftOperator.value =
    props.modelValue?.operator || props.operatorOptions[0]?.value || '';
  draftValue.value = props.modelValue?.value ?? '';
};

const isApplyDisabled = computed(() => {
  if (!draftOperator.value) return true;
  if (!operatorRequiresValue.value) return false;

  if (isNumericField.value) {
    return draftValue.value === '' || Number.isNaN(Number(draftValue.value));
  }

  return !String(draftValue.value || '').trim();
});

const resolveTeleportTarget = () => {
  const overlayElement = triggerRef.value?.closest('dialog[open], .modal-mask');
  teleportTarget.value = overlayElement || 'body';
};

const updateDropdownPosition = () => {
  if (!isOpen.value || !triggerRef.value) return;

  const rect = triggerRef.value.getBoundingClientRect();
  const viewportPadding = 8;
  const width = Math.min(
    Math.max(rect.width, 320),
    window.innerWidth - viewportPadding * 2
  );
  const left = Math.min(
    Math.max(rect.left, viewportPadding),
    window.innerWidth - width - viewportPadding
  );
  const top = Math.max(rect.bottom + 8, viewportPadding);
  const maxHeight = Math.max(window.innerHeight - top - viewportPadding, 160);

  dropdownStyle.value = {
    left: `${Math.round(left)}px`,
    maxHeight: `${Math.round(maxHeight)}px`,
    top: `${Math.round(top)}px`,
    width: `${Math.round(width)}px`,
  };
};

const toggleDropdown = () => {
  isOpen.value = !isOpen.value;
  if (!isOpen.value) return;

  syncDraftFromModel();
  resolveTeleportTarget();
  nextTick(() => {
    updateDropdownPosition();
  });
};

const applyFilter = () => {
  if (isApplyDisabled.value) return;

  emit(
    'update:modelValue',
    operatorRequiresValue.value
      ? { operator: draftOperator.value, value: draftValue.value }
      : { operator: draftOperator.value }
  );
  isOpen.value = false;
};

const clearFilter = () => {
  emit('update:modelValue', null);
  syncDraftFromModel();
  isOpen.value = false;
};

watch(
  () => props.modelValue,
  () => {
    if (!isOpen.value) {
      syncDraftFromModel();
    }
  },
  { deep: true, immediate: true }
);

watch(
  () => props.operatorOptions,
  () => {
    if (!draftOperator.value) {
      syncDraftFromModel();
    }
  },
  { deep: true, immediate: true }
);

watch(draftOperator, operator => {
  if (VALUELESS_OPERATORS.includes(operator)) {
    draftValue.value = '';
  }
});

watch(
  () => [draftOperator.value, draftValue.value, props.summaryLabel],
  () => {
    if (!isOpen.value) return;
    nextTick(() => updateDropdownPosition());
  }
);

useEventListener(window, 'resize', updateDropdownPosition);
useEventListener(window, 'scroll', updateDropdownPosition, {
  capture: true,
  passive: true,
});
</script>

<template>
  <div ref="triggerRef" class="relative max-w-full min-w-0">
    <OnClickOutside
      :options="{ ignore: ['.scheduling-advanced-filter-dropdown'] }"
      @trigger="isOpen = false"
    >
      <div class="relative">
        <Button
          size="sm"
          color="slate"
          variant="outline"
          justify="start"
          class="!h-10 !max-w-full !rounded-lg !bg-n-alpha-black2 !px-3 !py-2 !font-normal !outline-n-weak hover:!outline-n-slate-6"
          @click="toggleDropdown"
        >
          <span
            class="min-w-0 flex-1 truncate text-left text-sm text-n-slate-12"
          >
            {{ buttonLabel }}
          </span>
          <span
            class="ml-2 size-4 shrink-0 text-n-slate-10"
            :class="[isOpen ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down']"
            aria-hidden="true"
          />
        </Button>
      </div>

      <Teleport :to="teleportTarget">
        <div
          v-if="isOpen"
          class="scheduling-advanced-filter-dropdown fixed z-50 flex min-w-80 flex-col gap-3 rounded-2xl border border-n-weak bg-n-solid-2/95 p-3 shadow-xl outline outline-1 outline-n-container backdrop-blur-[16px]"
          :style="dropdownStyle"
        >
          <Select
            v-model:model-value="draftOperator"
            class="w-full"
            :options="operatorOptions"
          />

          <Input
            v-if="operatorRequiresValue && !isDateField && !isDateTimeField"
            v-model="draftValue"
            :type="isNumericField ? 'number' : 'text'"
            :placeholder="valuePlaceholder"
            :step="isNumericField ? 'any' : undefined"
          />

          <SchedulingDateTimeField
            v-else-if="operatorRequiresValue && isDateField"
            v-model="draftValue"
            type="date"
            :placeholder="valuePlaceholder"
          />

          <SchedulingDateTimeField
            v-else-if="operatorRequiresValue && isDateTimeField"
            v-model="draftValue"
            type="datetime"
            :placeholder="valuePlaceholder"
          />

          <div class="flex items-center justify-between gap-2">
            <Button
              size="sm"
              variant="ghost"
              color="slate"
              :label="clearLabel"
              @click="clearFilter"
            />
            <Button
              size="sm"
              color="slate"
              variant="solid"
              :label="applyLabel"
              :disabled="isApplyDisabled"
              @click="applyFilter"
            />
          </div>
        </div>
      </Teleport>
    </OnClickOutside>
  </div>
</template>
