<script setup>
import { storeToRefs } from 'pinia';
import { useInboxStore } from 'dashboard/stores/inboxes';
import WootReports from './components/WootReports.vue';

const inboxStore = useInboxStore();
const { getInboxes: inboxes } = storeToRefs(inboxStore);
const fetchInboxes = () => inboxStore.get();
</script>

<template>
  <WootReports
    key="inbox-reports"
    type="inbox"
    :items="inboxes"
    :fetch-items="fetchInboxes"
    :download-button-label="$t('INBOX_REPORTS.DOWNLOAD_INBOX_REPORTS')"
    :report-title="$t('INBOX_REPORTS.HEADER')"
  />
</template>
