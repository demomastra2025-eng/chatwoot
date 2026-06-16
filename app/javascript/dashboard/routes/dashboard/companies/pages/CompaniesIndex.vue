<script setup>
import { ref, computed, onMounted, reactive, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { debounce } from '@chatwoot/utils';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useCompaniesStore } from 'dashboard/stores/companies';
import CompaniesListLayout from 'dashboard/components-next/Companies/CompaniesListLayout.vue';
import CompaniesCard from 'dashboard/components-next/Companies/CompaniesCard/CompaniesCard.vue';
import CreateCompanyDialog from 'dashboard/components-next/Companies/CompanyForm/CreateCompanyDialog.vue';

const DEFAULT_SORT_FIELD = 'name';
const DEBOUNCE_DELAY = 300;

const companiesStore = useCompaniesStore();

const route = useRoute();
const router = useRouter();
const { t } = useI18n();
const { checkPermissions } = usePolicy();
const createCompanyDialogRef = ref(null);
const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const { updateUISettings, uiSettings } = useUISettings();

const companies = computed(() => companiesStore.getCompaniesList);
const meta = computed(() => companiesStore.getMeta);
const uiFlags = computed(() => companiesStore.getUIFlags);

const searchQuery = computed(() => route.query?.search || '');
const searchValue = ref(searchQuery.value);
const pageNumber = computed(() => Number(route.query?.page) || 1);
const companyUiActionQueriesReady = ref(false);

const parseSortSettings = (sortString = '') => {
  const hasDescending = sortString.startsWith('-');
  const sortField = hasDescending ? sortString.slice(1) : sortString;
  return {
    sort: sortField || DEFAULT_SORT_FIELD,
    order: hasDescending ? '-' : '',
  };
};

const { companies_sort_by: companySortBy = DEFAULT_SORT_FIELD } =
  uiSettings.value ?? {};
const sortPreference = route.query?.sort || companySortBy;
const { sort: initialSort, order: initialOrder } =
  parseSortSettings(sortPreference);

const sortState = reactive({
  activeSort: initialSort,
  activeOrdering: initialOrder,
});

const activeSort = computed(() => sortState.activeSort);
const activeOrdering = computed(() => sortState.activeOrdering);

const isFetchingList = computed(() => uiFlags.value.fetchingList);
const showCompanySettingsButton = computed(
  () =>
    checkPermissions(['administrator']) &&
    isFeatureEnabledonAccount.value(
      accountId.value,
      FEATURE_FLAGS.CUSTOM_ATTRIBUTES
    )
);

const buildSortAttr = () =>
  `${sortState.activeOrdering}${sortState.activeSort}`;

const sortParam = computed(() => buildSortAttr());

const updateURLParams = (page, search = '', sort = '') => {
  const query = {
    ...route.query,
    page: page.toString(),
  };

  if (search) {
    query.search = search;
  } else {
    delete query.search;
  }

  if (sort) {
    query.sort = sort;
  } else {
    delete query.sort;
  }

  router.replace({ query });
};

const fetchCompanies = async (page, search, sort) => {
  const currentPage = page ?? pageNumber.value;
  const currentSearch = search ?? searchQuery.value;
  const currentSort = sort ?? sortParam.value;

  // Only update URL if arguments were explicitly provided
  if (page !== undefined || search !== undefined || sort !== undefined) {
    updateURLParams(currentPage, currentSearch, currentSort);
  }

  if (currentSearch) {
    await companiesStore.search({
      search: currentSearch,
      page: currentPage,
      sort: currentSort,
    });
  } else {
    await companiesStore.get({
      page: currentPage,
      sort: currentSort,
    });
  }
};

const onSearch = debounce(query => {
  searchValue.value = query;
  fetchCompanies(1, query, sortParam.value);
}, DEBOUNCE_DELAY);

const onPageChange = page => {
  fetchCompanies(page, searchValue.value, sortParam.value);
};

const openCreateCompanyDialog = prefill => {
  createCompanyDialogRef.value?.openWithPrefill(prefill || null);
};

const openCompanySettings = () => {
  router.push({
    name: 'company_fields_settings_index',
    params: { accountId: route.params.accountId || accountId.value },
  });
};

const showCompany = companyId => {
  router.push({
    name: 'companies_dashboard_show',
    params: {
      accountId: route.params.accountId,
      companyId,
    },
  });
};

const createCompany = async company => {
  try {
    const createdCompany = await companiesStore.create(company);

    useAlert(t('COMPANIES.FORM.SUCCESS.CREATE'));
    createCompanyDialogRef.value?.onSuccess?.();
    showCompany(createdCompany.id);
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.CREATE'));
  }
};

const handleSort = async ({ sort, order }) => {
  Object.assign(sortState, { activeSort: sort, activeOrdering: order });

  await updateUISettings({
    companies_sort_by: buildSortAttr(),
  });

  fetchCompanies(1, searchValue.value, buildSortAttr());
};

const queryValue = key => {
  const value = route.query[key];
  return Array.isArray(value) ? value[0] : value;
};

const numericQueryValue = key => {
  const value = Number(queryValue(key));
  return Number.isFinite(value) && value > 0 ? value : '';
};

const companyPrefillKeys = [
  'action',
  'companyId',
  'description',
  'domain',
  'name',
  'source',
];

const clearCompanyPrefillQuery = async () => {
  const nextQuery = { ...route.query };
  companyPrefillKeys.forEach(key => {
    delete nextQuery[key];
  });

  await router.replace({ query: nextQuery });
};

const consumeCompanyPrefillQuery = async () => {
  if (queryValue('action') !== 'new') return;

  openCreateCompanyDialog({
    name: queryValue('name') || '',
    domain: queryValue('domain') || '',
    description: queryValue('description') || '',
  });
  await clearCompanyPrefillQuery();
};

const consumeCompanyOpenQuery = async () => {
  const companyId = numericQueryValue('companyId');
  if (!companyId) return false;

  try {
    if (!companies.value.some(company => Number(company.id) === companyId)) {
      await companiesStore.show(companyId);
    }

    companiesStore.resetCompanyDetailState?.();
    showCompany(companyId);
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.UPDATE'));
  } finally {
    await clearCompanyPrefillQuery();
  }

  return true;
};

onMounted(async () => {
  searchValue.value = searchQuery.value;
  await fetchCompanies();
  if (!(await consumeCompanyOpenQuery())) {
    await consumeCompanyPrefillQuery();
  }
  companyUiActionQueriesReady.value = true;
});

watch(
  () => [
    route.query?.companyId,
    route.query?.action,
    route.query?.source,
    route.query?.name,
    route.query?.domain,
    route.query?.description,
  ],
  async () => {
    if (!companyUiActionQueriesReady.value) return;
    if (await consumeCompanyOpenQuery()) return;
    await consumeCompanyPrefillQuery();
  }
);
</script>

<template>
  <CompaniesListLayout
    :search-value="searchValue"
    :header-title="t('COMPANIES.HEADER')"
    :create-button-label="t('COMPANIES.ACTIONS.ADD')"
    :current-page="pageNumber"
    :total-items="Number(meta.totalCount || 0)"
    :active-sort="activeSort"
    :active-ordering="activeOrdering"
    :is-fetching-list="isFetchingList"
    :show-settings-button="showCompanySettingsButton"
    :show-pagination-footer="!!companies.length"
    @update:current-page="onPageChange"
    @update:sort="handleSort"
    @search="onSearch"
    @create="openCreateCompanyDialog"
    @open-settings="openCompanySettings"
  >
    <div v-if="isFetchingList" class="flex items-center justify-center p-8">
      <span class="text-n-slate-11 text-base">{{
        t('COMPANIES.LOADING')
      }}</span>
    </div>
    <div
      v-else-if="companies.length === 0"
      class="flex items-center justify-center p-8"
    >
      <span class="text-n-slate-11 text-base">{{
        t('COMPANIES.EMPTY_STATE.TITLE')
      }}</span>
    </div>
    <div v-else class="flex flex-col gap-4">
      <CompaniesCard
        v-for="company in companies"
        :id="company.id"
        :key="company.id"
        :name="company.name"
        :domain="company.domain"
        :contacts-count="company.contactsCount || 0"
        :avatar-url="company.avatarUrl"
        :last-activity-at="company.lastActivityAt"
        @show-company="showCompany"
      />
    </div>
  </CompaniesListLayout>
  <CreateCompanyDialog ref="createCompanyDialogRef" @create="createCompany" />
</template>
