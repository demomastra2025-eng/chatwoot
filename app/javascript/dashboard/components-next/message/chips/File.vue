<script setup>
import { computed, ref, useAttrs } from 'vue';
import { useI18n } from 'vue-i18n';
import { downloadFile, getFileInfo } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { useAttachmentAvailability } from 'dashboard/composables/useAttachmentAvailability';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

import FileIcon from 'next/icon/FileIcon.vue';
import Icon from 'next/icon/Icon.vue';

const props = defineProps({
  attachment: {
    type: Object,
    required: true,
  },
});

defineOptions({
  inheritAttrs: false,
});

const { t } = useI18n();
const attrs = useAttrs();
const attachmentRef = computed(() => props.attachment);
const { isPurged, refreshAfterMediaFailure } =
  useAttachmentAvailability(attachmentRef);
const isDownloading = ref(false);

const fileDetails = computed(() => {
  return getFileInfo(props.attachment?.dataUrl || '');
});

const displayFileName = computed(() => {
  const { base, type } = fileDetails.value;
  const truncatedName = (str, maxLength, hasExt) =>
    str.length > maxLength
      ? `${str.substring(0, maxLength).trimEnd()}${hasExt ? '..' : '...'}`
      : str;

  return type
    ? `${truncatedName(base, 12, true)}.${type}`
    : truncatedName(base, 14, false);
});

const textColorClass = computed(() => {
  const colorMap = {
    '7z': 'dark:text-[#EDEEF0] text-[#2F265F]',
    csv: 'text-n-amber-12',
    doc: 'dark:text-[#D6E1FF] text-[#1F2D5C]', // indigo-12
    docx: 'dark:text-[#D6E1FF] text-[#1F2D5C]', // indigo-12
    json: 'text-n-slate-12',
    odt: 'dark:text-[#D6E1FF] text-[#1F2D5C]', // indigo-12
    p12: 'text-n-slate-12',
    pfx: 'text-n-slate-12',
    pdf: 'text-n-slate-12',
    ppt: 'dark:text-[#FFE0C2] text-[#582D1D]',
    pptx: 'dark:text-[#FFE0C2] text-[#582D1D]',
    rar: 'dark:text-[#EDEEF0] text-[#2F265F]',
    rtf: 'dark:text-[#D6E1FF] text-[#1F2D5C]', // indigo-12
    tar: 'dark:text-[#EDEEF0] text-[#2F265F]',
    txt: 'text-n-slate-12',
    xml: 'text-n-slate-12',
    xls: 'text-n-teal-12',
    xlsx: 'text-n-teal-12',
    zip: 'dark:text-[#EDEEF0] text-[#2F265F]',
  };

  return colorMap[fileDetails.value.type?.toLowerCase()] || 'text-n-slate-12';
});

const parsedText = computed(
  () => props.attachment?.parsedText || props.attachment?.transcribedText || ''
);

const handleDownload = async () => {
  if (isPurged.value || !props.attachment?.dataUrl) return;

  try {
    isDownloading.value = true;
    await downloadFile({
      url: props.attachment.dataUrl,
      type: props.attachment.fileType,
      extension: props.attachment.extension,
    });
  } catch {
    await refreshAfterMediaFailure();
    useAlert(t('GALLERY_VIEW.ERROR_DOWNLOADING'));
  } finally {
    isDownloading.value = false;
  }
};
</script>

<template>
  <div
    v-if="isPurged"
    class="rounded-lg bg-n-alpha-1 p-3 text-sm text-n-slate-11"
  >
    {{ t('COMPONENTS.MEDIA.LOADING_FAILED') }}
  </div>
  <div
    v-else
    class="max-w-[28rem] overflow-hidden rounded-lg border border-n-container bg-n-alpha-white"
  >
    <div
      v-bind="attrs"
      class="flex h-9 items-center gap-2 overflow-hidden px-2"
    >
      <FileIcon class="flex-shrink-0" :file-type="fileDetails.type" />
      <span
        class="flex-1 min-w-0 text-sm max-w-36"
        :title="fileDetails.name"
        :class="textColorClass"
      >
        {{ displayFileName }}
      </span>
      <button
        v-tooltip="t('CONVERSATION.DOWNLOAD')"
        type="button"
        class="flex-shrink-0 size-9 grid place-content-center cursor-pointer text-n-slate-11 hover:text-n-slate-12 transition-colors disabled:cursor-not-allowed"
        :disabled="isDownloading"
        @click.stop="handleDownload"
      >
        <Icon v-if="!isDownloading" icon="i-lucide-download" />
        <Spinner v-else :size="16" class="text-n-slate-11" />
      </button>
    </div>
    <div
      v-if="parsedText"
      class="max-h-32 overflow-y-auto whitespace-pre-wrap break-words border-t border-n-weak bg-n-alpha-1 px-3 py-2 text-xs leading-5 text-n-slate-12"
    >
      {{ parsedText }}
    </div>
  </div>
</template>
