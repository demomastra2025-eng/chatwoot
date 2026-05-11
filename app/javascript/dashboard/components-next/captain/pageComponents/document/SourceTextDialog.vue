<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  document: {
    type: Object,
    default: () => ({}),
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['close']);
const { t } = useI18n();
const dialogRef = ref(null);

const sourceText = computed(() => props.document?.source_text || '');
const hasSourceText = computed(() => sourceText.value.trim().length > 0);
const sourceTextSize = computed(() => {
  const bytes = props.document?.source_text_bytes || 0;
  if (!bytes) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
});

const handleClose = () => emit('close');

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    :title="t('CAPTAIN.DOCUMENTS.SOURCE_TEXT.TITLE')"
    :description="
      document?.name || t('CAPTAIN.DOCUMENTS.SOURCE_TEXT.DESCRIPTION')
    "
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
    width="3xl"
    @close="handleClose"
  >
    <div
      v-if="isLoading"
      class="flex min-h-64 items-center justify-center text-n-slate-11"
    >
      <Spinner />
    </div>
    <div v-else class="flex min-h-0 flex-col gap-4">
      <div class="flex flex-wrap items-center gap-2">
        <span
          class="rounded-full bg-n-alpha-2 px-2.5 py-1 text-xs text-n-slate-11"
        >
          {{
            t('CAPTAIN.DOCUMENTS.SOURCE_TEXT.SIZE', {
              size: sourceTextSize || '0 B',
            })
          }}
        </span>
      </div>

      <div
        v-if="hasSourceText"
        class="max-h-[60vh] overflow-auto rounded-xl border border-n-weak bg-n-alpha-2 p-4"
      >
        <pre
          class="m-0 whitespace-pre-wrap break-words font-mono text-sm leading-6 text-n-slate-12"
          >{{ sourceText }}</pre
        >
      </div>

      <div
        v-else
        class="rounded-xl border border-dashed border-n-weak bg-n-alpha-2 px-5 py-10 text-center"
      >
        <p class="m-0 text-sm font-medium text-n-slate-12">
          {{ t('CAPTAIN.DOCUMENTS.SOURCE_TEXT.EMPTY_TITLE') }}
        </p>
        <p class="mx-auto mb-0 mt-2 max-w-xl text-sm text-n-slate-11">
          {{ t('CAPTAIN.DOCUMENTS.SOURCE_TEXT.EMPTY_DESCRIPTION') }}
        </p>
      </div>
    </div>
    <template #footer />
  </Dialog>
</template>
