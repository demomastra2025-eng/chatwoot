<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import { canConfirmTaskCompletion } from './taskCompletion';

const props = defineProps({
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['confirm']);
const { t } = useI18n();

const dialogRef = ref(null);
const selectedTask = ref(null);
const note = ref('');
const confirmedWithoutNote = ref(false);

const isDisabled = computed(
  () =>
    !selectedTask.value ||
    !canConfirmTaskCompletion({
      confirmedWithoutNote: confirmedWithoutNote.value,
      note: note.value,
    })
);
const isCompleted = computed(() => Boolean(selectedTask.value?.completedAt));
const title = computed(() =>
  isCompleted.value
    ? t('CRM.TASKS.RESULT_DIALOG.CHANGE_TITLE')
    : t('CRM.TASKS.RESULT_DIALOG.TITLE')
);
const confirmLabel = computed(() =>
  isCompleted.value
    ? t('CRM.GENERAL.SAVE')
    : t('CRM.TASKS.RESULT_DIALOG.ACTION')
);

const open = task => {
  selectedTask.value = task;
  note.value = task?.outcomeNote || '';
  confirmedWithoutNote.value = Boolean(task?.completedAt && !note.value.trim());
  dialogRef.value?.open();
};

const close = () => {
  dialogRef.value?.close();
  selectedTask.value = null;
  note.value = '';
  confirmedWithoutNote.value = false;
};

const confirm = () => {
  if (isDisabled.value) return;

  emit('confirm', {
    note: note.value.trim(),
    task: selectedTask.value,
  });
};

defineExpose({ close, open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="lg"
    :title="title"
    :description="$t('CRM.TASKS.RESULT_DIALOG.DESCRIPTION')"
    :confirm-button-label="confirmLabel"
    :disable-confirm-button="isDisabled"
    :is-loading="props.isLoading"
    @confirm="confirm"
  >
    <div class="grid gap-4">
      <TextArea
        :label="$t('CRM.TASKS.RESULT_DIALOG.OPTIONAL_NOTE_LABEL')"
        :model-value="note"
        :placeholder="$t('CRM.TASKS.RESULT_DIALOG.OPTIONAL_NOTE_PLACEHOLDER')"
        auto-height
        min-height="6rem"
        max-height="none"
        @update:model-value="note = $event"
      />

      <label
        class="flex cursor-pointer items-start gap-3 rounded-xl border border-n-weak bg-n-alpha-black2 px-3 py-3"
      >
        <Checkbox v-model="confirmedWithoutNote" />
        <span class="grid gap-1">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('CRM.TASKS.RESULT_DIALOG.CONFIRM_WITHOUT_NOTE') }}
          </span>
          <span class="text-xs leading-5 text-n-slate-11">
            {{ $t('CRM.TASKS.RESULT_DIALOG.CONFIRM_WITHOUT_NOTE_HELP') }}
          </span>
        </span>
      </label>
    </div>
  </Dialog>
</template>
