<script setup>
import { ref, computed, onMounted, reactive } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAlert } from 'dashboard/composables';
import { debounce } from '@chatwoot/utils';
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
const createCompanyDialogRef = ref(null);
const expandedCompanyId = ref(null);

const { updateUISettings, uiSettings } = useUISettings();

const companies = computed(() => companiesStore.getCompaniesList);
const meta = computed(() => companiesStore.getMeta);
const uiFlags = computed(() => companiesStore.getUIFlags);

const searchQuery = computed(() => route.query?.search || '');
const searchValue = ref(searchQuery.value);
const pageNumber = computed(() => Number(route.query?.page) || 1);

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

const openCreateCompanyDialog = () => {
  createCompanyDialogRef.value?.dialogRef?.open();
};

const toggleCompany = companyId => {
  expandedCompanyId.value =
    expandedCompanyId.value === companyId ? null : companyId;
};

const createCompany = async company => {
  try {
    const createdCompany = await companiesStore.create(company);
    useAlert(t('COMPANIES.FORM.SUCCESS.CREATE'));
    createCompanyDialogRef.value?.onSuccess?.();
    await fetchCompanies(1, searchValue.value, sortParam.value);
    expandedCompanyId.value = createdCompany.id;
  } catch {
    useAlert(t('COMPANIES.FORM.ERROR.CREATE'));
  }
};

const collapseDeletedCompany = companyId => {
  if (expandedCompanyId.value === companyId) {
    expandedCompanyId.value = null;
  }
};

const handleSort = async ({ sort, order }) => {
  Object.assign(sortState, { activeSort: sort, activeOrdering: order });

  await updateUISettings({
    companies_sort_by: buildSortAttr(),
  });

  fetchCompanies(1, searchValue.value, buildSortAttr());
};

onMounted(() => {
  searchValue.value = searchQuery.value;
  fetchCompanies();
});
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
    :show-pagination-footer="!!companies.length"
    @update:current-page="onPageChange"
    @update:sort="handleSort"
    @search="onSearch"
    @create="openCreateCompanyDialog"
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
        :description="company.description"
        :avatar-url="company.avatarUrl"
        :updated-at="company.updatedAt"
        :is-expanded="expandedCompanyId === company.id"
        @toggle="toggleCompany(company.id)"
        @deleted="collapseDeletedCompany"
      />
    </div>
  </CompaniesListLayout>
  <CreateCompanyDialog ref="createCompanyDialogRef" @create="createCompany" />
</template>
