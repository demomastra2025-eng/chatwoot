<script setup>
import { computed, reactive, watch } from 'vue';
import { useToggle } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';

import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const props = defineProps({
  buttonLabel: {
    type: String,
    default: '',
  },
  confirmLabel: {
    type: String,
    default: '',
  },
  cancelLabel: {
    type: String,
    default: '',
  },
  typeLabel: {
    type: String,
    default: '',
  },
  groupLabel: {
    type: String,
    default: '',
  },
  groupPlaceholder: {
    type: String,
    default: '',
  },
  placeholder: {
    type: String,
    default: '',
  },
  typeOptions: {
    type: Array,
    default: () => [],
  },
  defaultGroups: {
    type: Object,
    default: () => ({}),
  },
  groupLabels: {
    type: Object,
    default: () => ({}),
  },
  enableCaptainFields: {
    type: Boolean,
    default: false,
  },
  enableCaptainTools: {
    type: Boolean,
    default: false,
  },
  captainContextAssistantId: {
    type: Number,
    default: null,
  },
  captainContextAccess: {
    type: Object,
    default: null,
  },
  captainToolAccess: {
    type: Object,
    default: null,
  },
  captainToolScope: {
    type: String,
    default: 'agent',
  },
});

const emit = defineEmits(['add']);

const modelValue = defineModel({
  type: String,
  default: '',
});

const [showPopover, togglePopover] = useToggle();
const isStructuredMode = computed(() => props.typeOptions.length > 0);

const firstType = computed(() => props.typeOptions[0]?.value || '');
const resolveDisplayGroup = value => props.groupLabels[value] || value;
const resolveStoredGroup = value => {
  const normalizedValue = value?.toString().trim() || '';
  const matchedEntry = Object.entries(props.groupLabels).find(
    ([, label]) => label === normalizedValue
  );

  return matchedEntry?.[0] || normalizedValue;
};

const state = reactive({
  type: firstType.value,
  group: props.defaultGroups[firstType.value] || '',
  content: '',
});

const groupInputValue = computed({
  get: () => resolveDisplayGroup(state.group),
  set: value => {
    state.group = resolveStoredGroup(value);
  },
});

const resetState = () => {
  state.type = firstType.value;
  state.group = props.defaultGroups[firstType.value] || '';
  state.content = '';
  modelValue.value = '';
};

watch(
  firstType,
  value => {
    if (!state.type) {
      state.type = value;
      state.group = props.defaultGroups[value] || '';
    }
  },
  { immediate: true }
);

watch(
  () => state.type,
  (newType, oldType) => {
    const previousDefault = props.defaultGroups[oldType] || '';
    if (!state.group || state.group === previousDefault) {
      state.group = props.defaultGroups[newType] || '';
    }
  }
);

const onClickAdd = () => {
  const content = isStructuredMode.value
    ? state.content?.trim()
    : modelValue.value?.trim();

  if (!content) return;

  if (!isStructuredMode.value) {
    emit('add', content);
    resetState();
    togglePopover(false);
    return;
  }

  emit('add', {
    type: state.type,
    group: state.group.trim() || props.defaultGroups[state.type] || '',
    content,
    enabled: true,
  });

  resetState();
  togglePopover(false);
};

const onClickCancel = () => {
  resetState();
  togglePopover(false);
};
</script>

<template>
  <div
    v-on-click-outside="() => togglePopover(false)"
    class="inline-flex relative"
  >
    <Button
      :label="buttonLabel"
      sm
      slate
      class="flex-shrink-0"
      @click="togglePopover(!showPopover)"
    />
    <div
      v-if="showPopover"
      class="absolute top-9 z-50 flex w-[32rem] flex-col gap-5 rounded-xl border border-n-weak bg-n-alpha-3 p-4 shadow-md backdrop-blur-[100px] ltr:left-0 rtl:right-0"
    >
      <div v-if="isStructuredMode" class="grid grid-cols-2 gap-3">
        <div class="flex flex-col gap-1">
          <span class="text-sm font-medium text-n-slate-12">{{
            typeLabel
          }}</span>
          <Select v-model="state.type" :options="typeOptions" class="w-full" />
        </div>
        <Input
          v-model="groupInputValue"
          :label="groupLabel"
          :placeholder="groupPlaceholder"
        />
      </div>

      <Editor
        v-if="isStructuredMode"
        v-model="state.content"
        override-line-breaks
        focus-on-mount
        :placeholder="placeholder"
        :show-character-count="false"
        :enable-captain-tools="enableCaptainTools"
        :enable-captain-fields="enableCaptainFields"
        :captain-context-assistant-id="captainContextAssistantId"
        :captain-context-access="captainContextAccess"
        :captain-tool-access="captainToolAccess"
        :captain-tool-scope="captainToolScope"
      />
      <Editor
        v-else
        v-model="modelValue"
        override-line-breaks
        focus-on-mount
        :placeholder="placeholder"
        :show-character-count="false"
        :enable-captain-tools="enableCaptainTools"
        :enable-captain-fields="enableCaptainFields"
        :captain-context-assistant-id="captainContextAssistantId"
        :captain-context-access="captainContextAccess"
        :captain-tool-access="captainToolAccess"
        :captain-tool-scope="captainToolScope"
      />
      <div class="flex justify-between gap-2">
        <Button
          :label="cancelLabel"
          sm
          link
          slate
          class="h-10 hover:!no-underline"
          @click="onClickCancel"
        />
        <Button
          :label="confirmLabel"
          sm
          color="slate"
          variant="outline"
          @click="onClickAdd"
        />
      </div>
    </div>
  </div>
</template>
