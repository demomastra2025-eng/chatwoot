<script setup>
import { computed, reactive, watch } from 'vue';

import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const props = defineProps({
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

const emit = defineEmits(['add', 'cancel']);

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
  const content = state.content?.trim();
  if (!content) return;

  emit('add', {
    type: state.type,
    group: state.group.trim() || props.defaultGroups[state.type] || '',
    content,
    enabled: true,
  });

  resetState();
};

const onClickCancel = () => {
  resetState();
  emit('cancel');
};
</script>

<template>
  <CardLayout class="[&>div]:!py-5" layout="row">
    <div class="flex w-full flex-col gap-4">
      <div class="grid gap-3 md:grid-cols-2">
        <div class="flex flex-col gap-1">
          <span class="text-sm font-medium text-n-slate-12">
            {{ typeLabel }}
          </span>
          <Select v-model="state.type" :options="typeOptions" class="w-full" />
        </div>
        <Input
          v-model="groupInputValue"
          :label="groupLabel"
          :placeholder="groupPlaceholder"
        />
      </div>

      <Editor
        v-model="state.content"
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

      <div class="flex items-center justify-end gap-2">
        <Button faded slate sm :label="cancelLabel" @click="onClickCancel" />
        <Button sm :label="confirmLabel" @click="onClickAdd" />
      </div>
    </div>
  </CardLayout>
</template>
