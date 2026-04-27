<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength, maxLength } from '@vuelidate/validators';

import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

defineProps({
  assistantId: {
    type: Number,
    default: null,
  },
});

const emit = defineEmits(['add', 'cancel']);

const { t } = useI18n();
const SCENARIO_DESCRIPTION_MAX_LENGTH = 2000;
const SCENARIO_INSTRUCTION_MAX_LENGTH = 20_000;

const state = reactive({
  title: '',
  description: '',
  instruction: '',
});
const isSubmitting = ref(false);

const rules = {
  title: { required, minLength: minLength(1) },
  description: {
    required,
    maxLength: maxLength(SCENARIO_DESCRIPTION_MAX_LENGTH),
  },
  instruction: {
    required,
    maxLength: maxLength(SCENARIO_INSTRUCTION_MAX_LENGTH),
  },
};

const v$ = useVuelidate(rules, state);

const titleError = computed(() =>
  v$.value.title.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.ERROR')
    : ''
);

const descriptionError = computed(() =>
  v$.value.description.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.ERROR')
    : ''
);

const instructionError = computed(() =>
  v$.value.instruction.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.ERROR')
    : ''
);

const resetState = () => {
  state.title = '';
  state.description = '';
  state.instruction = '';
  v$.value.$reset();
};

const onClickAdd = async () => {
  v$.value.$touch();
  if (v$.value.$invalid || isSubmitting.value) return;

  isSubmitting.value = true;
  emit(
    'add',
    {
      ...state,
      enabled: true,
    },
    created => {
      isSubmitting.value = false;

      if (created) {
        resetState();
      }
    }
  );
};

const onClickCancel = () => {
  if (isSubmitting.value) return;

  resetState();
  emit('cancel');
};
</script>

<template>
  <CardLayout class="[&>div]:!py-5" layout="row">
    <div class="flex w-full flex-col gap-4">
      <Input
        v-model="state.title"
        :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.LABEL')"
        :placeholder="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.PLACEHOLDER')
        "
        :message="titleError"
        :message-type="titleError ? 'error' : 'info'"
      />

      <TextArea
        v-model="state.description"
        :label="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.LABEL')
        "
        :placeholder="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.PLACEHOLDER')
        "
        :message="descriptionError"
        :message-type="descriptionError ? 'error' : 'info'"
        :max-length="SCENARIO_DESCRIPTION_MAX_LENGTH"
        show-character-count
      />

      <Editor
        v-model="state.instruction"
        override-line-breaks
        focus-on-mount
        :label="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.LABEL')
        "
        :placeholder="
          t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.PLACEHOLDER')
        "
        :message="instructionError"
        :message-type="instructionError ? 'error' : 'info'"
        :max-length="SCENARIO_INSTRUCTION_MAX_LENGTH"
        enable-captain-tools
        enable-captain-fields
        :captain-context-assistant-id="assistantId"
      />

      <div class="flex items-center justify-end gap-2">
        <Button
          faded
          slate
          sm
          :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.CANCEL')"
          :disabled="isSubmitting"
          @click="onClickCancel"
        />
        <Button
          sm
          :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.CREATE')"
          :is-loading="isSubmitting"
          :disabled="isSubmitting"
          @click="onClickAdd"
        />
      </div>
    </div>
  </CardLayout>
</template>
