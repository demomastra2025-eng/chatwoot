<script setup>
import { reactive, computed, ref, watch, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength, requiredIf } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';

import Input from 'dashboard/components-next/input/Input.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import AgentSelector from 'dashboard/components-next/captain/assistant/AgentSelector.vue';
import {
  externalAssistants,
  knowledgeAccessPayload,
  knowledgeAccessSignature,
  knowledgeAssistantIds,
  knowledgeVisibility,
} from 'dashboard/components-next/captain/assistant/assistantAccess';

const props = defineProps({
  mode: {
    type: String,
    required: true,
    validator: value => ['edit', 'create'].includes(value),
  },
  response: {
    type: Object,
    default: () => ({}),
  },
  assistantId: {
    type: [Number, String],
    default: null,
  },
});

const emit = defineEmits(['submit', 'cancel']);
const { t } = useI18n();
const store = useStore();

const formState = {
  uiFlags: useMapGetter('captainResponses/getUIFlags'),
  assistants: useMapGetter('captainAssistants/getRecords'),
  assistantUiFlags: useMapGetter('captainAssistants/getUIFlags'),
};

const initialState = {
  question: '',
  answer: '',
  visibility: 'general',
  selectedAssistantIds: props.assistantId ? [Number(props.assistantId)] : [],
};

const state = reactive({ ...initialState });
const savedAccess = ref('');
const accessChanged = computed(
  () =>
    props.mode === 'create' ||
    knowledgeAccessSignature(state.visibility, state.selectedAssistantIds) !==
      savedAccess.value
);

const showAssistantSelector = computed(() => state.visibility === 'personal');
const availableAssistants = computed(() =>
  externalAssistants(formState.assistants.value)
);

const validationRules = {
  question: { required, minLength: minLength(1) },
  answer: { required, minLength: minLength(1) },
  selectedAssistantIds: {
    required: requiredIf(
      () => showAssistantSelector.value && accessChanged.value
    ),
  },
};

const v$ = useVuelidate(validationRules, state);

const isLoading = computed(() => formState.uiFlags.value.creatingItem);

const getErrorMessage = (field, errorKey) => {
  return v$.value[field].$error
    ? t(`CAPTAIN.RESPONSES.FORM.${errorKey}.ERROR`)
    : '';
};

const formErrors = computed(() => ({
  question: getErrorMessage('question', 'QUESTION'),
  answer: getErrorMessage('answer', 'ANSWER'),
  assistant:
    v$.value.selectedAssistantIds.$error && showAssistantSelector.value
      ? t('CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_REQUIRED')
      : '',
}));

const visibilityOptions = computed(() => [
  {
    value: 'general',
    label: t('CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.GENERAL'),
  },
  {
    value: 'personal',
    label: t('CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.PERSONAL'),
  },
]);

const handleCancel = () => emit('cancel');

const prepareDocumentDetails = () => ({
  question: state.question,
  answer: state.answer,
  ...(accessChanged.value
    ? knowledgeAccessPayload(state.visibility, state.selectedAssistantIds)
    : {}),
});

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) {
    return;
  }

  emit('submit', prepareDocumentDetails());
};

const updateStateFromResponse = response => {
  if (!response) return;

  const { question, answer } = response;

  Object.assign(state, {
    question,
    answer,
    visibility: knowledgeVisibility(response),
    selectedAssistantIds: knowledgeAssistantIds(response),
  });
  savedAccess.value = knowledgeAccessSignature(
    state.visibility,
    state.selectedAssistantIds
  );
};

watch(
  () => props.response,
  newResponse => {
    if (props.mode === 'edit' && newResponse) {
      updateStateFromResponse(newResponse);
    }
  },
  { immediate: true }
);

const ensureAssistantsLoaded = () => {
  if (formState.assistantUiFlags.value.fetchingList) return;
  if (formState.assistants.value.length) return;

  store.dispatch('captainAssistants/get');
};

watch(
  () => state.visibility,
  visibility => {
    if (visibility === 'personal') ensureAssistantsLoaded();
  }
);

onMounted(() => {
  if (showAssistantSelector.value) {
    ensureAssistantsLoaded();
  }
});
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
    <Input
      v-model="state.question"
      :label="t('CAPTAIN.RESPONSES.FORM.QUESTION.LABEL')"
      :placeholder="t('CAPTAIN.RESPONSES.FORM.QUESTION.PLACEHOLDER')"
      :message="formErrors.question"
      :message-type="formErrors.question ? 'error' : 'info'"
    />
    <Editor
      v-model="state.answer"
      override-line-breaks
      :label="t('CAPTAIN.RESPONSES.FORM.ANSWER.LABEL')"
      :placeholder="t('CAPTAIN.RESPONSES.FORM.ANSWER.PLACEHOLDER')"
      :message="formErrors.answer"
      :max-length="10000"
      :message-type="formErrors.answer ? 'error' : 'info'"
    />
    <div class="flex flex-col gap-1">
      <label
        for="responseVisibility"
        class="mb-0.5 text-sm font-medium text-n-slate-12"
      >
        {{ t('CAPTAIN.KNOWLEDGE_VISIBILITY.LABEL') }}
      </label>
      <ComboBox
        id="responseVisibility"
        v-model="state.visibility"
        :options="visibilityOptions"
        class="[&>div>button]:bg-n-alpha-black2"
      />
      <p class="m-0 text-xs text-n-slate-11">
        {{ t('CAPTAIN.KNOWLEDGE_VISIBILITY.HELP_TEXT') }}
      </p>
    </div>
    <div v-if="showAssistantSelector" class="flex flex-col gap-1">
      <AgentSelector
        v-model="state.selectedAssistantIds"
        :assistants="availableAssistants"
        :disabled="formState.assistantUiFlags.value.fetchingList"
        :label="t('CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_LABEL')"
      />
      <p
        class="m-0 text-xs"
        :class="formErrors.assistant ? 'text-n-ruby-9' : 'text-n-slate-11'"
      >
        {{
          formErrors.assistant ||
          t('CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_HELP_TEXT')
        }}
      </p>
    </div>
    <div class="flex items-center justify-between w-full gap-3">
      <Button
        type="button"
        variant="faded"
        color="slate"
        :label="t('CAPTAIN.FORM.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        type="submit"
        :label="t(`CAPTAIN.FORM.${mode.toUpperCase()}`)"
        class="w-full"
        :is-loading="isLoading"
        :disabled="isLoading"
      />
    </div>
  </form>
</template>
