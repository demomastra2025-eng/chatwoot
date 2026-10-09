<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { downloadFile } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { useAttachmentAvailability } from 'dashboard/composables/useAttachmentAvailability';

import { useMessageContext } from '../provider.js';
import BaseBubble from './Base.vue';
import BaseAttachmentBubble from './BaseAttachment.vue';
import FileIcon from 'next/icon/FileIcon.vue';
import Icon from 'next/icon/Icon.vue';

const { attachments } = useMessageContext();

const { t } = useI18n();
const attachment = computed(() => attachments.value[0]);
const { isPurged, refreshAfterMediaFailure } =
  useAttachmentAvailability(attachment);

const url = computed(() => {
  return isPurged.value ? '' : attachment.value.dataUrl;
});

const fileName = computed(() => {
  if (url.value) {
    const filename = url.value.substring(url.value.lastIndexOf('/') + 1);
    return filename || t('CONVERSATION.UNKNOWN_FILE_TYPE');
  }
  return t('CONVERSATION.UNKNOWN_FILE_TYPE');
});

const fileType = computed(() => {
  return fileName.value.split('.').pop();
});

const handleDownload = async () => {
  if (isPurged.value || !url.value) return;

  try {
    await downloadFile({
      url: url.value,
      type: attachment.value.fileType,
      extension: attachment.value.extension,
    });
  } catch {
    await refreshAfterMediaFailure();
    useAlert(t('GALLERY_VIEW.ERROR_DOWNLOADING'));
  }
};
</script>

<template>
  <BaseBubble
    v-if="isPurged"
    class="flex items-center gap-1 p-3 text-sm text-n-slate-11"
    data-bubble-name="attachment-unavailable"
  >
    <Icon icon="i-lucide-circle-off" />
    {{ t('COMPONENTS.MEDIA.LOADING_FAILED') }}
  </BaseBubble>
  <BaseAttachmentBubble
    v-else
    icon="i-teenyicons-user-circle-solid"
    icon-bg-color="bg-n-alpha-3 dark:bg-n-alpha-white"
    sender-translation-key="CONVERSATION.SHARED_ATTACHMENT.FILE"
    :content="decodeURI(fileName)"
    :action="{
      onClick: handleDownload,
      label: $t('CONVERSATION.DOWNLOAD'),
    }"
  >
    <template #icon>
      <FileIcon :file-type="fileType" class="size-4" />
    </template>
  </BaseAttachmentBubble>
</template>
