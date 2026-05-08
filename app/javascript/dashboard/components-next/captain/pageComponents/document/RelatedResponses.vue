<script setup>
import { ref, computed, watch } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';
import ResponseCard from '../../assistant/ResponseCard.vue';
const props = defineProps({
  captainDocument: {
    type: Object,
    required: true,
  },
});
const emit = defineEmits(['close']);
const { t } = useI18n();
const store = useStore();
const dialogRef = ref(null);
const currentPage = ref(1);
const itemsPerPage = 25;

const uiFlags = useMapGetter('captainResponses/getUIFlags');
const responses = useMapGetter('captainResponses/getRecords');
const meta = useMapGetter('captainResponses/getMeta');
const isFetching = computed(() => uiFlags.value.fetchingList);
const totalCount = computed(() => meta.value.totalCount || 0);
const showPagination = computed(() => totalCount.value > itemsPerPage);

const fetchResponses = (page = 1) => {
  if (!props.captainDocument?.id || !props.captainDocument?.assistant?.id) {
    return null;
  }

  currentPage.value = page;
  return store.dispatch('captainResponses/get', {
    assistantId: props.captainDocument.assistant.id,
    documentId: props.captainDocument.id,
    page,
  });
};

const handleClose = () => {
  emit('close');
};

watch(
  () => props.captainDocument.id,
  () => fetchResponses(1),
  { immediate: true }
);
defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    :title="`${t('CAPTAIN.DOCUMENTS.RELATED_RESPONSES.TITLE')} (${totalCount})`"
    :description="t('CAPTAIN.DOCUMENTS.RELATED_RESPONSES.DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    overflow-y-auto
    width="3xl"
    @close="handleClose"
  >
    <div
      v-if="isFetching"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>
    <div v-else class="flex flex-col gap-3 min-h-48">
      <ResponseCard
        v-for="response in responses"
        :id="response.id"
        :key="response.id"
        :question="response.question"
        :status="response.status"
        :answer="response.answer"
        :assistant="response.assistant"
        :created-at="response.created_at"
        :updated-at="response.updated_at"
        compact
      />
      <PaginationFooter
        v-if="showPagination"
        :current-page="currentPage"
        :total-items="totalCount"
        :items-per-page="itemsPerPage"
        class="-mx-6 mt-2"
        @update:current-page="fetchResponses"
      />
    </div>
  </Dialog>
</template>
