<script setup>
import { computed, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  companyData: {
    type: Object,
    default: null,
  },
  isDetailsView: {
    type: Boolean,
    default: false,
  },
  isNewCompany: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['update']);
const { t } = useI18n();

const defaultState = {
  id: null,
  name: '',
  domain: '',
  description: '',
};

const state = reactive({ ...defaultState });

const isFormInvalid = computed(() => !state.name?.trim());

const syncState = company => {
  Object.assign(state, {
    id: company?.id ?? null,
    name: company?.name ?? '',
    domain: company?.domain ?? '',
    description: company?.description ?? '',
  });
};

watch(
  () => [props.companyData?.id, props.companyData?.updatedAt],
  () => {
    if (!props.companyData && props.isNewCompany) {
      Object.assign(state, defaultState);
      return;
    }

    syncState(props.companyData);
  },
  { immediate: true }
);

watch(
  state,
  () => {
    emit('update', {
      id: state.id,
      name: state.name.trim(),
      domain: state.domain.trim(),
      description: state.description.trim(),
    });
  },
  { deep: true }
);

const resetForm = () => {
  Object.assign(state, defaultState);
};

defineExpose({
  state,
  resetForm,
  isFormInvalid,
});
</script>

<template>
  <div class="flex flex-col gap-5">
    <Input
      v-model="state.name"
      :label="t('COMPANIES.FORM.NAME.LABEL')"
      :placeholder="t('COMPANIES.FORM.NAME.PLACEHOLDER')"
      :message="
        !state.name?.trim() ? t('COMPANIES.FORM.VALIDATION.NAME_REQUIRED') : ''
      "
      :message-type="!state.name?.trim() ? 'error' : 'info'"
      :custom-input-class="[
        !isDetailsView ? '[&:not(.error,.focus)]:!outline-transparent' : '',
      ]"
    />

    <Input
      v-model="state.domain"
      :label="t('COMPANIES.FORM.DOMAIN.LABEL')"
      :placeholder="t('COMPANIES.FORM.DOMAIN.PLACEHOLDER')"
      :custom-input-class="[
        !isDetailsView ? '[&:not(.error,.focus)]:!outline-transparent' : '',
      ]"
    />

    <TextArea
      v-model="state.description"
      :label="t('COMPANIES.FORM.DESCRIPTION.LABEL')"
      :placeholder="t('COMPANIES.FORM.DESCRIPTION.PLACEHOLDER')"
      rows="4"
      :custom-text-area-class="
        !isDetailsView ? '[&:not(.error,.focus)]:!outline-transparent' : ''
      "
    />
  </div>
</template>
