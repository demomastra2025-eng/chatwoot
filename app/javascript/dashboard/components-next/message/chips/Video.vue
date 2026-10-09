<script setup>
import { computed, ref } from 'vue';
import Icon from 'next/icon/Icon.vue';
import { useSnakeCase } from 'dashboard/composables/useTransformKeys';
import { useAttachmentAvailability } from 'dashboard/composables/useAttachmentAvailability';
import { useMessageContext } from '../provider.js';
import GalleryView from 'dashboard/components/widgets/conversation/components/GalleryView.vue';

const props = defineProps({
  attachment: {
    type: Object,
    required: true,
  },
});

const showGallery = ref(false);
const hasError = ref(false);
const attachment = computed(() => props.attachment);
const { isPurged, refreshAfterMediaFailure } =
  useAttachmentAvailability(attachment);

const { filteredCurrentChatAttachments } = useMessageContext();

const handleError = async () => {
  hasError.value = true;
  await refreshAfterMediaFailure();
};
</script>

<template>
  <div
    v-if="hasError || isPurged"
    class="flex size-[72px] items-center justify-center gap-1 rounded-xl bg-n-alpha-1 px-2 text-center text-xs text-n-slate-11"
  >
    <Icon icon="i-lucide-circle-off" />
    {{ $t('COMPONENTS.MEDIA.LOADING_FAILED') }}
  </div>
  <div
    v-else
    class="size-[72px] overflow-hidden contain-content rounded-xl cursor-pointer relative group"
    @click="showGallery = true"
  >
    <video
      :src="attachment.dataUrl"
      class="w-full h-full object-cover"
      muted
      playsInline
      @error="handleError"
    />
    <div
      class="absolute w-full h-full inset-0 p-1 flex items-center justify-center"
    >
      <div
        class="size-7 bg-n-slate-1/60 backdrop-blur-sm rounded-full overflow-hidden shadow-[0_5px_15px_rgba(0,0,0,0.4)]"
      >
        <Icon
          icon="i-teenyicons-play-small-solid"
          class="size-7 text-n-slate-12/80 backdrop-blur"
        />
      </div>
    </div>
  </div>
  <GalleryView
    v-if="showGallery && !isPurged"
    v-model:show="showGallery"
    :attachment="useSnakeCase(attachment)"
    :all-attachments="filteredCurrentChatAttachments"
    @error="handleError"
    @close="() => (showGallery = false)"
  />
</template>
