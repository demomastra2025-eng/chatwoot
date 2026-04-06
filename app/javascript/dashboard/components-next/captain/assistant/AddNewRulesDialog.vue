<script setup>
import { useToggle } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';

import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

defineProps({
  placeholder: {
    type: String,
    default: '',
  },
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
const onClickAdd = () => {
  if (!modelValue.value?.trim()) return;
  emit('add', modelValue.value.trim());
  modelValue.value = '';
  togglePopover(false);
};

const onClickCancel = () => {
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
      class="absolute w-[26.5rem] top-9 z-50 ltr:left-0 rtl:right-0 flex flex-col gap-5 bg-n-alpha-3 backdrop-blur-[100px] p-4 rounded-xl border border-n-weak shadow-md"
    >
      <Editor
        v-model="modelValue"
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
      <div class="flex gap-2 justify-between">
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
