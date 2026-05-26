<script setup>
import { computed, ref, nextTick, watch } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useRoute } from 'vue-router';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useAccount } from 'dashboard/composables/useAccount';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import { usePolicy } from 'dashboard/composables/usePolicy';

import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';
import DocumentCard from 'dashboard/components-next/captain/assistant/DocumentCard.vue';
import BulkSelectBar from 'dashboard/components-next/captain/assistant/BulkSelectBar.vue';
import BulkDeleteDialog from 'dashboard/components-next/captain/pageComponents/BulkDeleteDialog.vue';
import Policy from 'dashboard/components/policy.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import RelatedResponses from 'dashboard/components-next/captain/pageComponents/document/RelatedResponses.vue';
import CreateDocumentDialog from 'dashboard/components-next/captain/pageComponents/document/CreateDocumentDialog.vue';
import SourceTextDialog from 'dashboard/components-next/captain/pageComponents/document/SourceTextDialog.vue';
import DocumentPageEmptyState from 'dashboard/components-next/captain/pageComponents/emptyStates/DocumentPageEmptyState.vue';
import FeatureSpotlightPopover from 'dashboard/components-next/feature-spotlight/FeatureSpotlightPopover.vue';
import LimitBanner from 'dashboard/components-next/captain/pageComponents/document/LimitBanner.vue';

const route = useRoute();
const store = useStore();
const { t } = useI18n();
const { checkPermissions } = usePolicy();

const { isOnChatwootCloud } = useAccount();
const uiFlags = useMapGetter('captainDocuments/getUIFlags');
const documents = useMapGetter('captainDocuments/getRecords');
const isFetching = computed(() => uiFlags.value.fetchingList);
const documentsMeta = useMapGetter('captainDocuments/getMeta');

const selectedAssistantId = computed(() => Number(route.params.assistantId));
const canManageDocuments = computed(() => checkPermissions(['administrator']));

const selectedDocument = ref(null);
const deleteDocumentDialog = ref(null);
const bulkDeleteDialog = ref(null);
const bulkSelectedIds = ref(new Set());
const hoveredCard = ref(null);

const handleDelete = () => {
  deleteDocumentDialog.value.dialogRef.open();
};

const showRelatedResponses = ref(false);
const showCreateDialog = ref(false);
const showSourceTextDialog = ref(false);
const createDocumentDialog = ref(null);
const relationQuestionDialog = ref(null);
const sourceTextDialog = ref(null);
const sourceTextDocument = ref({});

const handleShowRelatedDocument = () => {
  showRelatedResponses.value = true;
  nextTick(() => relationQuestionDialog.value.dialogRef.open());
};

const handleShowSourceText = async id => {
  showSourceTextDialog.value = true;
  sourceTextDocument.value = selectedDocument.value || {};
  nextTick(() => sourceTextDialog.value.dialogRef.open());
  try {
    sourceTextDocument.value = await store.dispatch(
      'captainDocuments/sourceText',
      id
    );
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.DOCUMENTS.SOURCE_TEXT.ERROR_MESSAGE')
    );
  }
};

const handleCreateDocument = () => {
  showCreateDialog.value = true;
  nextTick(() => createDocumentDialog.value.dialogRef.open());
};

const handleRelatedResponseClose = () => {
  showRelatedResponses.value = false;
};

const handleSourceTextClose = () => {
  showSourceTextDialog.value = false;
  sourceTextDocument.value = {};
};

const handleCreateDialogClose = () => {
  showCreateDialog.value = false;
};

function fetchDocuments(page = 1) {
  const filterParams = { page };

  if (selectedAssistantId.value) {
    filterParams.assistantId = selectedAssistantId.value;
  }
  store.dispatch('captainDocuments/get', filterParams);
}

async function handleResync(id) {
  try {
    await store.dispatch('captainDocuments/resync', id);
    useAlert(t('CAPTAIN.DOCUMENTS.RESYNC.SUCCESS_MESSAGE'));
    fetchDocuments(documentsMeta.value.page || 1);
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.DOCUMENTS.RESYNC.ERROR_MESSAGE')
    );
  }
}

async function handleRefreshChangedOnly(id) {
  try {
    await store.dispatch('captainDocuments/refreshChangedOnly', id);
    useAlert(t('CAPTAIN.DOCUMENTS.DELTA_SYNC.SUCCESS_MESSAGE'));
    fetchDocuments(documentsMeta.value.page || 1);
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.DOCUMENTS.DELTA_SYNC.ERROR_MESSAGE')
    );
  }
}

async function handleRetryFailed(id) {
  try {
    await store.dispatch('captainDocuments/retryFailed', id);
    useAlert(t('CAPTAIN.DOCUMENTS.RETRY_FAILED.SUCCESS_MESSAGE'));
    fetchDocuments(documentsMeta.value.page || 1);
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('CAPTAIN.DOCUMENTS.RETRY_FAILED.ERROR_MESSAGE')
    );
  }
}

const handleAction = ({ action, id }) => {
  selectedDocument.value = documents.value.find(
    captainDocument => id === captainDocument.id
  );

  nextTick(() => {
    if (action === 'delete') {
      handleDelete();
    } else if (action === 'viewRelatedQuestions') {
      handleShowRelatedDocument();
    } else if (action === 'viewSourceText') {
      handleShowSourceText(id);
    } else if (action === 'resync') {
      handleResync(id);
    } else if (action === 'refreshChangedOnly') {
      handleRefreshChangedOnly(id);
    } else if (action === 'retryFailed') {
      handleRetryFailed(id);
    }
  });
};

const onPageChange = page => {
  const hadSelection = bulkSelectedIds.value.size > 0;
  fetchDocuments(page);

  if (hadSelection) {
    bulkSelectedIds.value = new Set();
  }
};

const onDeleteSuccess = () => {
  if (documents.value?.length === 0 && documentsMeta.value?.page > 1) {
    onPageChange(documentsMeta.value.page - 1);
  }
};

const buildSelectedCountLabel = computed(() => {
  const count = documents.value?.length || 0;
  const isAllSelected = bulkSelectedIds.value.size === count && count > 0;
  return isAllSelected
    ? t('CAPTAIN.DOCUMENTS.UNSELECT_ALL', { count })
    : t('CAPTAIN.DOCUMENTS.SELECT_ALL', { count });
});

const selectedCountLabel = computed(() => {
  return t('CAPTAIN.DOCUMENTS.SELECTED', {
    count: bulkSelectedIds.value.size,
  });
});

const hasBulkSelection = computed(() => bulkSelectedIds.value.size > 0);

const shouldShowSelectionControl = docId => {
  return (
    canManageDocuments.value &&
    (hoveredCard.value === docId || hasBulkSelection.value)
  );
};

const handleCardHover = (isHovered, id) => {
  hoveredCard.value = isHovered ? id : null;
};

const handleCardSelect = id => {
  if (!canManageDocuments.value) return;
  const selected = new Set(bulkSelectedIds.value);
  selected[selected.has(id) ? 'delete' : 'add'](id);
  bulkSelectedIds.value = selected;
};

const fetchDocumentsAfterBulkAction = () => {
  const hasNoDocumentsLeft = documents.value?.length === 0;
  const currentPage = documentsMeta.value?.page;

  if (hasNoDocumentsLeft) {
    const pageToFetch = currentPage > 1 ? currentPage - 1 : currentPage;
    fetchDocuments(pageToFetch);
  } else {
    fetchDocuments(currentPage);
  }

  bulkSelectedIds.value = new Set();
};

const onBulkDeleteSuccess = () => {
  fetchDocumentsAfterBulkAction();
};

watch(
  selectedAssistantId,
  currentAssistantId => {
    if (!currentAssistantId) {
      return;
    }

    bulkSelectedIds.value = new Set();
    fetchDocuments();
  },
  { immediate: true }
);
</script>

<template>
  <PageLayout
    :header-title="$t('CAPTAIN.DOCUMENTS.HEADER')"
    :button-label="$t('CAPTAIN.DOCUMENTS.ADD_NEW')"
    :button-policy="['administrator']"
    :total-count="documentsMeta.totalCount"
    :current-page="documentsMeta.page"
    :show-pagination-footer="!isFetching && !!documents.length"
    :is-fetching="isFetching"
    :is-empty="!documents.length"
    :show-know-more="false"
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    @update:current-page="onPageChange"
    @click="handleCreateDocument"
  >
    <template #subHeader>
      <Policy :permissions="['administrator']">
        <BulkSelectBar
          v-model="bulkSelectedIds"
          :all-items="documents"
          :select-all-label="buildSelectedCountLabel"
          :selected-count-label="selectedCountLabel"
          :delete-label="$t('CAPTAIN.DOCUMENTS.BULK_DELETE_BUTTON')"
          class="w-fit"
          :class="{ 'mb-2': bulkSelectedIds.size > 0 }"
          @bulk-delete="bulkDeleteDialog.dialogRef.open()"
        />
      </Policy>
    </template>

    <template #knowMore>
      <FeatureSpotlightPopover
        :button-label="$t('CAPTAIN.HEADER_KNOW_MORE')"
        :title="$t('CAPTAIN.DOCUMENTS.EMPTY_STATE.FEATURE_SPOTLIGHT.TITLE')"
        :note="$t('CAPTAIN.DOCUMENTS.EMPTY_STATE.FEATURE_SPOTLIGHT.NOTE')"
        :hide-actions="!isOnChatwootCloud"
        fallback-thumbnail="/assets/images/dashboard/captain/document-popover-light.svg"
        fallback-thumbnail-dark="/assets/images/dashboard/captain/document-popover-dark.svg"
        learn-more-url="https://chwt.app/captain-document"
      />
    </template>

    <template #emptyState>
      <DocumentPageEmptyState @click="handleCreateDocument" />
    </template>

    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #body>
      <LimitBanner class="mb-5" />

      <div class="flex flex-col gap-4">
        <DocumentCard
          v-for="doc in documents"
          :id="doc.id"
          :key="doc.id"
          :name="doc.name || doc.external_link"
          :external-link="doc.external_link"
          :display-url="doc.display_url"
          :assistant="doc.assistant"
          :source-mode="doc.source_mode"
          :sync-status="doc.sync_status"
          :refresh-mode="doc.refresh_mode"
          :pages-processed="doc.pages_processed"
          :pages-total="doc.pages_total"
          :failed-urls-count="doc.failed_urls_count"
          :embedding-status-summary="doc.embedding_status_summary"
          :last-error="doc.last_error"
          :last-synced-at="doc.last_synced_at"
          :created-at="doc.created_at"
          :is-selected="canManageDocuments && bulkSelectedIds.has(doc.id)"
          :selectable="canManageDocuments"
          :show-selection-control="shouldShowSelectionControl(doc.id)"
          :show-menu="!bulkSelectedIds.has(doc.id)"
          @action="handleAction"
          @select="handleCardSelect"
          @hover="isHovered => handleCardHover(isHovered, doc.id)"
        />
      </div>
    </template>

    <RelatedResponses
      v-if="showRelatedResponses"
      ref="relationQuestionDialog"
      :captain-document="selectedDocument"
      @close="handleRelatedResponseClose"
    />
    <CreateDocumentDialog
      v-if="showCreateDialog"
      ref="createDocumentDialog"
      :assistant-id="selectedAssistantId"
      @close="handleCreateDialogClose"
    />
    <SourceTextDialog
      v-if="showSourceTextDialog"
      ref="sourceTextDialog"
      :document="sourceTextDocument"
      :is-loading="uiFlags.fetchingSourceText"
      @close="handleSourceTextClose"
    />
    <DeleteDialog
      v-if="selectedDocument"
      ref="deleteDocumentDialog"
      :entity="selectedDocument"
      type="Documents"
      @delete-success="onDeleteSuccess"
    />
    <BulkDeleteDialog
      v-if="bulkSelectedIds"
      ref="bulkDeleteDialog"
      :bulk-ids="bulkSelectedIds"
      type="AssistantDocument"
      @delete-success="onBulkDeleteSuccess"
    />
  </PageLayout>
</template>
