<script setup>
import { computed, onMounted, ref, shallowRef, watch } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { debounce } from '@chatwoot/utils';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import SchedulingResourcesAPI from 'dashboard/api/scheduling/resources';
import SchedulingServicesAPI from 'dashboard/api/scheduling/services';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import ResponseCard from 'dashboard/components-next/captain/assistant/ResponseCard.vue';
import KnowledgeGraphCloud from 'dashboard/components-next/captain/assistant/KnowledgeGraphCloud.vue';
import ResponsePageEmptyState from 'dashboard/components-next/captain/pageComponents/emptyStates/ResponsePageEmptyState.vue';
import LimitBanner from 'dashboard/components-next/captain/pageComponents/response/LimitBanner.vue';

const store = useStore();
const uiFlags = useMapGetter('captainResponses/getUIFlags');
const responseMeta = useMapGetter('captainResponses/getMeta');
const responses = useMapGetter('captainResponses/getRecords');

const doctors = shallowRef([]);
const services = shallowRef([]);
const serviceStats = shallowRef([]);
const isFetchingClinicData = ref(false);

const isFetching = computed(
  () =>
    uiFlags.value.fetchingList &&
    !responses.value.length &&
    !doctors.value.length &&
    !services.value.length &&
    isFetchingClinicData.value
);

const isGraphEmpty = computed(
  () =>
    !responses.value.length && !doctors.value.length && !services.value.length
);

const searchQuery = ref('');
const viewMode = ref('graph');
const { t } = useI18n();
const route = useRoute();
const router = useRouter();

const selectedAssistantId = computed(() => route.params.assistantId);

const handleNavigationAction = ({ id, type }) => {
  if (type === 'Conversation') {
    router.push({
      name: 'inbox_conversation',
      params: { conversation_id: id },
    });
  }
};

const updateURLWithFilters = (page, search) => {
  const query = {
    page: page || 1,
  };

  if (search) {
    query.search = search;
  }

  router.replace({ query });
};

const fetchResponses = (page = 1) => {
  const filterParams = { page, status: 'approved' };

  if (selectedAssistantId.value) {
    filterParams.assistantId = selectedAssistantId.value;
  }
  if (searchQuery.value) {
    filterParams.search = searchQuery.value;
  }

  updateURLWithFilters(page, searchQuery.value);
  store.dispatch('captainResponses/get', filterParams);
};

const fetchClinicGraphData = async () => {
  isFetchingClinicData.value = true;
  try {
    const [resourcesRes, servicesRes] = await Promise.all([
      SchedulingResourcesAPI.get({
        include_service_stats: true,
        lightweight: true,
      }).catch(() => null),
      SchedulingServicesAPI.get().catch(() => null),
    ]);
    doctors.value = Array.isArray(resourcesRes?.data?.payload)
      ? resourcesRes.data.payload
      : [];
    serviceStats.value = Array.isArray(resourcesRes?.data?.meta?.service_stats)
      ? resourcesRes.data.meta.service_stats
      : [];
    services.value = Array.isArray(servicesRes?.data?.payload)
      ? servicesRes.data.payload
      : [];
  } finally {
    isFetchingClinicData.value = false;
  }
};

const onPageChange = page => {
  fetchResponses(page);
};

const debouncedSearch = debounce(async () => {
  fetchResponses(1);
}, 500);

const initializeFromURL = () => {
  if (route.query.search) {
    searchQuery.value = route.query.search;
  }
  const pageFromURL = parseInt(route.query.page, 10) || 1;
  fetchResponses(pageFromURL);
};

watch(
  selectedAssistantId,
  () => {
    initializeFromURL();
  },
  { immediate: true }
);

onMounted(() => {
  initializeFromURL();
  fetchClinicGraphData();
});
</script>

<template>
  <PageLayout
    :total-count="responseMeta.totalCount"
    :current-page="responseMeta.page"
    :header-title="$t('CAPTAIN.NAV.KNOWLEDGE')"
    :is-fetching="isFetching"
    :is-empty="viewMode === 'list' ? !responses.length : isGraphEmpty"
    :show-know-more="false"
    :content-width="viewMode === 'graph' ? 'full' : 'default'"
    :full-bleed="viewMode === 'graph'"
    :show-pagination-footer="
      viewMode === 'list' && !isFetching && !!responses.length
    "
    :feature-flag="FEATURE_FLAGS.CAPTAIN"
    @update:current-page="onPageChange"
  >
    <template #search>
      <div class="flex gap-3 justify-between w-full items-center">
        <Input
          v-model="searchQuery"
          :placeholder="$t('CAPTAIN.RESPONSES.SEARCH_PLACEHOLDER')"
          class="w-64"
          size="sm"
          type="search"
          autofocus
          @input="debouncedSearch"
        />

        <div
          class="inline-flex items-center gap-1 rounded-xl border border-n-weak bg-n-solid-2 p-1"
        >
          <Button
            :label="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.VIEW_GRAPH')"
            icon="i-lucide-network"
            size="xs"
            :color="viewMode === 'graph' ? 'blue' : 'slate'"
            :variant="viewMode === 'graph' ? 'faded' : 'ghost'"
            data-testid="faq-view-graph"
            @click="viewMode = 'graph'"
          />
          <Button
            :label="t('CAPTAIN.KNOWLEDGE_BASE.GRAPH.VIEW_LIST')"
            icon="i-lucide-list"
            size="xs"
            :color="viewMode === 'list' ? 'blue' : 'slate'"
            :variant="viewMode === 'list' ? 'faded' : 'ghost'"
            data-testid="faq-view-list"
            @click="viewMode = 'list'"
          />
        </div>
      </div>
    </template>

    <template #emptyState>
      <ResponsePageEmptyState />
    </template>

    <template #paywall>
      <CaptainPaywall />
    </template>

    <template #body>
      <LimitBanner v-if="viewMode === 'list'" class="mb-5" />

      <KnowledgeGraphCloud
        v-if="viewMode === 'graph'"
        :responses="responses"
        :doctors="doctors"
        :services="services"
        :service-stats="serviceStats"
        :search-query="searchQuery"
        @navigate="handleNavigationAction"
      />

      <div v-else class="flex flex-col gap-3">
        <ResponseCard
          v-for="response in responses"
          :id="response.id"
          :key="response.id"
          :question="response.question"
          :answer="response.answer"
          :documentable="response.documentable"
          :status="response.status"
          :visibility="response.visibility"
          :assistant="response.assistant"
          :allowed-assistant-ids="response.allowed_assistant_ids"
          :restricted-to-assistants="response.restricted_to_assistants"
          :created-at="response.created_at"
          :updated-at="response.updated_at"
          :selectable="false"
          :show-menu="false"
          :show-actions="false"
          @navigate="handleNavigationAction"
        />
      </div>
    </template>
  </PageLayout>
</template>
