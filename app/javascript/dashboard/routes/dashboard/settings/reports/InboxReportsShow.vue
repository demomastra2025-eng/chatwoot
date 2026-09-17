<script setup>
import { storeToRefs } from 'pinia';
import { useInboxStore, useInboxStoreGetter } from 'dashboard/stores/inboxes';
import { useRoute } from 'vue-router';

import WootReports from './components/WootReports.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const route = useRoute();
const inboxStore = useInboxStore();
const { getInboxes: inboxes } = storeToRefs(inboxStore);
const inbox = useInboxStoreGetter('getInboxById', route.params.id);
const fetchInboxes = () => inboxStore.get();
</script>

<template>
  <WootReports
    v-if="inbox.id"
    :key="inbox.id"
    type="inbox"
    :items="inboxes"
    :fetch-items="fetchInboxes"
    :selected-item="inbox"
    :download-button-label="$t('INBOX_REPORTS.DOWNLOAD_INBOX_REPORTS')"
    :report-title="$t('INBOX_REPORTS.HEADER')"
    has-back-button
  />
  <div v-else class="w-full py-20">
    <Spinner class="mx-auto" />
  </div>
</template>
