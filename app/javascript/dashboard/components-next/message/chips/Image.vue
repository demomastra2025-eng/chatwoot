<script setup>
import { computed, ref, watch } from 'vue';
import Icon from 'next/icon/Icon.vue';
import { useLoadWithRetry } from 'dashboard/composables/loadWithRetry';
import { useMapGetter } from 'dashboard/composables/store';
import { useSnakeCase } from 'dashboard/composables/useTransformKeys';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useMessageContext } from '../provider.js';

import GalleryView from 'dashboard/components/widgets/conversation/components/GalleryView.vue';

const props = defineProps({
  attachment: {
    type: Object,
    required: true,
  },
});

const localHasError = ref(false);
const showGallery = ref(false);

const { filteredCurrentChatAttachments, inboxId } = useMessageContext();
const inboxGetter = useMapGetter('inboxes/getInbox');
const { isLoaded, hasError, loadWithRetry } = useLoadWithRetry({
  max_retry: 4,
  backoff: 500,
});

const inbox = computed(() => inboxGetter.value(inboxId.value) || {});
const shouldRetryLoad = computed(() => {
  return inbox.value?.channel_type === INBOX_TYPES.WHATSAPP_WEB;
});
const imageSrc = computed(() => props.attachment.dataUrl);
const shouldShowError = computed(() => {
  return shouldRetryLoad.value ? hasError.value : localHasError.value;
});
const shouldRenderImage = computed(() => {
  return !shouldRetryLoad.value || isLoaded.value;
});

const handleError = () => {
  if (shouldRetryLoad.value) {
    hasError.value = true;
    return;
  }

  localHasError.value = true;
};

watch(
  [shouldRetryLoad, imageSrc],
  async ([shouldRetry, src]) => {
    localHasError.value = false;
    hasError.value = false;
    isLoaded.value = !shouldRetry;

    if (!shouldRetry || !src) {
      return;
    }

    await loadWithRetry(src);
  },
  { immediate: true }
);
</script>

<template>
  <div
    class="size-[72px] overflow-hidden contain-content rounded-xl cursor-pointer"
    @click="showGallery = true"
  >
    <div
      v-if="shouldShowError"
      class="flex flex-col items-center justify-center gap-1 text-xs text-center rounded-lg size-full bg-n-alpha-1 text-n-slate-11"
    >
      <Icon icon="i-lucide-circle-off" class="text-n-slate-11" />
      {{ $t('COMPONENTS.MEDIA.LOADING_FAILED') }}
    </div>
    <img
      v-else-if="shouldRenderImage"
      class="object-cover w-full h-full skip-context-menu"
      :src="imageSrc"
      @error="handleError"
    />
  </div>
  <GalleryView
    v-if="showGallery"
    v-model:show="showGallery"
    :attachment="useSnakeCase(attachment)"
    :all-attachments="filteredCurrentChatAttachments"
    @error="handleError"
    @close="() => (showGallery = false)"
  />
</template>
