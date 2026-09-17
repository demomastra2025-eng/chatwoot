<script setup>
import { storeToRefs } from 'pinia';
import { ref } from 'vue';
import { useInboxStore } from 'dashboard/stores/inboxes';
import ReportHeader from './components/ReportHeader.vue';
import SummaryReports from './components/SummaryReports.vue';
import V4Button from 'dashboard/components-next/button/Button.vue';

const summarReportsRef = ref(null);
const inboxStore = useInboxStore();
const { getInboxes: inboxes } = storeToRefs(inboxStore);
const fetchInboxes = () => inboxStore.get();

const onDownloadClick = () => {
  summarReportsRef.value.downloadReports();
};
</script>

<template>
  <ReportHeader
    :header-title="$t('INBOX_REPORTS.HEADER')"
    :header-description="$t('INBOX_REPORTS.DESCRIPTION')"
  >
    <V4Button
      :label="$t('INBOX_REPORTS.DOWNLOAD_INBOX_REPORTS')"
      icon="i-ph-download-simple"
      size="sm"
      @click="onDownloadClick"
    />
  </ReportHeader>

  <SummaryReports
    ref="summarReportsRef"
    action-key="summaryReports/fetchInboxSummaryReports"
    summary-key="summaryReports/getInboxSummaryReports"
    type="inbox"
    :items="inboxes"
    :fetch-items="fetchInboxes"
  />
</template>
