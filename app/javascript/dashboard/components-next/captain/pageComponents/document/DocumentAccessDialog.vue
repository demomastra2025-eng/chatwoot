<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import AgentSelector from 'dashboard/components-next/captain/assistant/AgentSelector.vue';
import {
  externalAssistants,
  knowledgeAccessPayload,
  knowledgeAccessSignature,
  knowledgeAssistantIds,
  knowledgeVisibility,
} from 'dashboard/components-next/captain/assistant/assistantAccess';

const props = defineProps({
  document: { type: Object, required: true },
});
const emit = defineEmits(['close']);
const { t } = useI18n();
const store = useStore();
const dialogRef = ref(null);
const visibility = ref('general');
const selectedIds = ref([]);
const savedAccess = ref('');
const isSaving = ref(false);
const assistants = useMapGetter('captainAssistants/getRecords');
const uiFlags = useMapGetter('captainAssistants/getUIFlags');
const availableAssistants = computed(() =>
  externalAssistants(assistants.value)
);
const visibilityOptions = computed(() =>
  ['general', 'personal'].map(value => ({
    value,
    label: t(`CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.${value.toUpperCase()}`),
  }))
);
watch(
  () => props.document,
  document => {
    visibility.value = knowledgeVisibility(document);
    selectedIds.value = knowledgeAssistantIds(document);
    savedAccess.value = knowledgeAccessSignature(
      visibility.value,
      selectedIds.value
    );
  },
  { immediate: true }
);
onMounted(() => store.dispatch('captainAssistants/get'));
const save = async () => {
  if (
    knowledgeAccessSignature(visibility.value, selectedIds.value) ===
    savedAccess.value
  ) {
    dialogRef.value.close();
    return;
  }
  if (visibility.value === 'personal' && !selectedIds.value.length) {
    useAlert(t('CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_REQUIRED'));
    return;
  }
  isSaving.value = true;
  try {
    await store.dispatch('captainDocuments/update', {
      id: props.document.id,
      document: knowledgeAccessPayload(visibility.value, selectedIds.value),
    });
    useAlert(t('CAPTAIN.KNOWLEDGE_VISIBILITY.SAVE_SUCCESS'));
    dialogRef.value.close();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.KNOWLEDGE_VISIBILITY.SAVE_ERROR')
    );
  } finally {
    isSaving.value = false;
  }
};
defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="t('CAPTAIN.KNOWLEDGE_VISIBILITY.EDIT_ACCESS')"
    :description="document.name || document.external_link"
    :confirm-button-label="t('CAPTAIN.ASSISTANTS.FORM.SAVE')"
    :is-loading="isSaving"
    :disable-confirm-button="isSaving || uiFlags.fetchingList"
    @confirm="save"
    @close="emit('close')"
  >
    <div class="flex flex-col gap-4">
      <Select v-model="visibility" :options="visibilityOptions" />
      <AgentSelector
        v-if="visibility === 'personal'"
        v-model="selectedIds"
        :assistants="availableAssistants"
        :disabled="isSaving || uiFlags.fetchingList"
        :label="t('CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_LABEL')"
      />
      <p class="m-0 text-xs text-n-slate-11">
        {{ t('CAPTAIN.KNOWLEDGE_VISIBILITY.HELP_TEXT') }}
      </p>
    </div>
  </Dialog>
</template>
