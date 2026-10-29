<script setup>
import { useAlert } from 'dashboard/composables';
import { computed, onBeforeMount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStoreGetters, useStore } from 'dashboard/composables/store';
import { picoSearch } from '@scmmishra/pico-search';

import AddLabel from './AddLabel.vue';
import EditLabel from './EditLabel.vue';
import MetaAdsAutoTagSettings from './MetaAdsAutoTagSettings.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';
import {
  isSystemMetaAdsLabel,
  labelDisplayTitle,
  labelDisplayTitleWithoutMarker,
  labelMarkerColor,
  labelMarkerEmoji,
  labelMarkerType,
} from 'dashboard/helper/labels';

const getters = useStoreGetters();
const store = useStore();
const { t } = useI18n();

const loading = ref({});
const showAddPopup = ref(false);
const showEditPopup = ref(false);
const showDeleteConfirmationPopup = ref(false);
const selectedLabel = ref({});
const searchQuery = ref('');

const records = computed(() => getters['labels/getLabels'].value);

const filteredRecords = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return records.value;
  return picoSearch(records.value, query, [
    { name: 'display_title', weight: 4 },
    'title',
    'description',
  ]);
});
const uiFlags = computed(() => getters['labels/getUIFlags'].value);

const deleteMessage = computed(
  () => ` ${labelDisplayTitle(selectedLabel.value)}?`
);

const hasLoadedOnce = ref(false);

const refreshLabels = async () => {
  try {
    await store.dispatch('labels/get');
  } finally {
    hasLoadedOnce.value = true;
  }
};

const openAddPopup = () => {
  showAddPopup.value = true;
};
const hideAddPopup = () => {
  showAddPopup.value = false;
};

const openEditPopup = response => {
  showEditPopup.value = true;
  selectedLabel.value = response;
};
const hideEditPopup = () => {
  showEditPopup.value = false;
};

const openDeletePopup = response => {
  showDeleteConfirmationPopup.value = true;
  selectedLabel.value = response;
};
const closeDeletePopup = () => {
  showDeleteConfirmationPopup.value = false;
};

const deleteLabel = async id => {
  try {
    await store.dispatch('labels/delete', id);
    useAlert(t('LABEL_MGMT.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    const errorMessage =
      error?.message || t('LABEL_MGMT.DELETE.API.ERROR_MESSAGE');
    useAlert(errorMessage);
  } finally {
    loading.value[selectedLabel.value.id] = false;
  }
};

const confirmDeletion = () => {
  loading.value[selectedLabel.value.id] = true;
  closeDeletePopup();
  deleteLabel(selectedLabel.value.id);
};

const tableHeaders = computed(() => {
  return [
    t('LABEL_MGMT.LIST.TABLE_HEADER.NAME'),
    t('LABEL_MGMT.LIST.TABLE_HEADER.DESCRIPTION'),
    t('LABEL_MGMT.LIST.TABLE_HEADER.MARKER'),
    t('LABEL_MGMT.LIST.TABLE_HEADER.ACTION'),
  ];
});

onBeforeMount(() => {
  refreshLabels();
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching && !hasLoadedOnce"
    :loading-message="$t('LABEL_MGMT.LOADING')"
    :no-records-found="false"
    :no-records-message="$t('LABEL_MGMT.LIST.404')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('LABEL_MGMT.HEADER')"
        :description="$t('LABEL_MGMT.DESCRIPTION')"
        :link-text="$t('LABEL_MGMT.LEARN_MORE')"
        :search-placeholder="$t('LABEL_MGMT.SEARCH_PLACEHOLDER')"
        feature-name="labels"
      >
        <template v-if="records?.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('LABEL_MGMT.COUNT', { n: filteredRecords.length }) }}
          </span>
        </template>
        <template #actions>
          <Button
            :label="$t('LABEL_MGMT.HEADER_BTN_TXT')"
            size="sm"
            @click="openAddPopup"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #preBody>
      <MetaAdsAutoTagSettings @updated="refreshLabels" />
    </template>

    <template #body>
      <BaseTable
        :headers="tableHeaders"
        :items="filteredRecords"
        :no-data-message="
          searchQuery ? $t('LABEL_MGMT.NO_RESULTS') : $t('LABEL_MGMT.LIST.404')
        "
      >
        <template #row="{ items }">
          <BaseTableRow v-for="label in items" :key="label.title" :item="label">
            <template #default>
              <BaseTableCell>
                <div
                  v-if="isSystemMetaAdsLabel(label)"
                  class="inline-flex items-center gap-2"
                >
                  <span
                    class="inline-flex h-6 items-center gap-1 rounded-full border border-n-blue-4 bg-n-blue-3 px-2.5 text-xs font-medium text-n-blue-11 dark:border-n-blue-6 dark:bg-n-blue-4/30"
                  >
                    <span
                      class="i-lucide-megaphone size-3"
                      aria-hidden="true"
                    />
                    <span>{{ labelDisplayTitleWithoutMarker(label) }}</span>
                  </span>
                  <span class="text-xs text-n-slate-10">
                    {{ $t('LABEL_MGMT.META_ADS.SYSTEM_BADGE') }}
                  </span>
                </div>
                <span v-else class="text-body-main text-n-slate-12">
                  {{ labelDisplayTitleWithoutMarker(label) }}
                </span>
              </BaseTableCell>

              <BaseTableCell>
                <span class="text-body-main text-n-slate-11">
                  {{ label.description }}
                </span>
              </BaseTableCell>

              <BaseTableCell>
                <div class="flex items-center">
                  <span
                    v-if="labelMarkerType(label) === 'emoji'"
                    class="ltr:mr-2 rtl:ml-2 text-xl leading-none"
                  >
                    {{ labelMarkerEmoji(label) }}
                  </span>
                  <span
                    v-else
                    class="size-2 ltr:mr-2 rtl:ml-2 rounded-sm"
                    :style="{ backgroundColor: labelMarkerColor(label) }"
                  />
                  <span
                    v-if="labelMarkerType(label) === 'color'"
                    class="text-body-main text-n-slate-12"
                  >
                    {{ label.color }}
                  </span>
                </div>
              </BaseTableCell>

              <BaseTableCell align="end">
                <div class="flex gap-3 justify-end flex-shrink-0">
                  <Button
                    v-tooltip.top="$t('LABEL_MGMT.FORM.EDIT')"
                    icon="i-woot-edit-pen"
                    slate
                    sm
                    :is-loading="loading[label.id]"
                    @click="openEditPopup(label)"
                  />
                  <Button
                    v-tooltip.top="$t('LABEL_MGMT.FORM.DELETE')"
                    icon="i-woot-bin"
                    slate
                    sm
                    class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
                    :is-loading="loading[label.id]"
                    @click="openDeletePopup(label)"
                  />
                </div>
              </BaseTableCell>
            </template>
          </BaseTableRow>
        </template>
      </BaseTable>
    </template>

    <woot-modal v-model:show="showAddPopup" @close="hideAddPopup">
      <AddLabel @close="hideAddPopup" />
    </woot-modal>

    <woot-modal v-model:show="showEditPopup" @close="hideEditPopup">
      <EditLabel :selected-response="selectedLabel" @close="hideEditPopup" />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteConfirmationPopup"
      :on-close="closeDeletePopup"
      :on-confirm="confirmDeletion"
      :title="$t('LABEL_MGMT.DELETE.CONFIRM.TITLE')"
      :message="$t('LABEL_MGMT.DELETE.CONFIRM.MESSAGE')"
      :message-value="deleteMessage"
      :confirm-text="$t('LABEL_MGMT.DELETE.CONFIRM.YES')"
      :reject-text="$t('LABEL_MGMT.DELETE.CONFIRM.NO')"
    />
  </SettingsLayout>
</template>
