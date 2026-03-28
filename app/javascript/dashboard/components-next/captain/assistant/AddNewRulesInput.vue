<script setup>
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

defineProps({
  placeholder: {
    type: String,
    default: '',
  },
  label: {
    type: String,
    default: '',
  },
  enableCaptainFields: {
    type: Boolean,
    default: false,
  },
  captainContextAssistantId: {
    type: Number,
    default: null,
  },
});

const emit = defineEmits(['add']);

const modelValue = defineModel({
  type: String,
  default: '',
});

const onClickAdd = () => {
  if (!modelValue.value?.trim()) return;
  emit('add', modelValue.value.trim());
  modelValue.value = '';
};
</script>

<template>
  <div
    class="flex py-3 ltr:pl-3 rtl:pr-3 ltr:pr-4 rtl:pl-4 items-start gap-3 rounded-xl bg-n-solid-2 outline-1 outline outline-n-container"
  >
    <Icon icon="i-lucide-plus" class="text-n-slate-10 size-5 flex-shrink-0" />

    <Editor
      v-model="modelValue"
      :placeholder="placeholder"
      :show-character-count="false"
      :enable-captain-fields="enableCaptainFields"
      :captain-context-assistant-id="captainContextAssistantId"
      class="flex-1"
    />
    <Button
      :label="label"
      ghost
      xs
      slate
      class="!text-sm !text-n-slate-11 flex-shrink-0"
      @click="onClickAdd"
    />
  </div>
</template>
