<script setup>
import { computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';

import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import OutboundWorkspaceLayout from 'dashboard/components-next/Outbound/OutboundWorkspaceLayout.vue';
import {
  BaseTable,
  BaseTableCell,
  BaseTableRow,
} from 'dashboard/components-next/table';

const { t } = useI18n();
const router = useRouter();
const store = useStore();
const { accountScopedRoute } = useAccount();

const segments = useMapGetter('customViews/getContactCustomViews');
const uiFlags = useMapGetter('customViews/getUIFlags');
const audienceSegments = computed(() => segments.value || []);
const isFetching = computed(() => uiFlags.value?.isFetching);

const tableHeaders = computed(() => {
  return [
    t('OUTBOUND_WORKSPACE.AUDIENCES.TABLE.NAME'),
    t('OUTBOUND_WORKSPACE.AUDIENCES.TABLE.FILTERS'),
    t('OUTBOUND_WORKSPACE.AUDIENCES.TABLE.ACTIONS'),
  ];
});

const fetchAudiences = async () => {
  await store.dispatch('customViews/get', 'contact');
};

const getFilterCount = segment => {
  return Object.keys(segment?.query?.payload || {}).length;
};

const openAudience = segment => {
  router.push(
    accountScopedRoute('contacts_dashboard_segments_index', {
      segmentId: segment.id,
    })
  );
};

const openContacts = () => {
  router.push(accountScopedRoute('contacts_dashboard_index'));
};

onMounted(() => {
  fetchAudiences();
});
</script>

<template>
  <OutboundWorkspaceLayout
    :title="$t('OUTBOUND_WORKSPACE.AUDIENCES.TITLE')"
    :description="$t('OUTBOUND_WORKSPACE.AUDIENCES.DESCRIPTION')"
  >
    <template #meta>
      <span>
        {{
          $t('OUTBOUND_WORKSPACE.TOUCHES.COUNT', {
            n: audienceSegments.length,
          })
        }}
      </span>
    </template>

    <template #actions>
      <Button
        :label="$t('OUTBOUND_WORKSPACE.AUDIENCES.MANAGE_CONTACTS')"
        slate
        size="sm"
        @click="openContacts"
      />
    </template>

    <div
      v-if="isFetching"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>

    <div v-else class="grid gap-6">
      <section
        class="rounded-3xl bg-n-surface-2 p-5 outline outline-1 outline-n-container shadow-sm"
      >
        <div
          class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between"
        >
          <div class="min-w-0">
            <h2 class="mb-1 text-lg font-semibold text-n-slate-12">
              {{ $t('OUTBOUND_WORKSPACE.AUDIENCES.TITLE') }}
            </h2>
            <p class="max-w-3xl mb-0 text-sm leading-6 text-n-slate-11">
              {{ $t('OUTBOUND_WORKSPACE.AUDIENCES.SUBTITLE') }}
            </p>
          </div>
          <div class="shrink-0 rounded-2xl bg-n-brand/8 px-4 py-3 text-center">
            <p
              class="mb-1 text-xs font-medium uppercase tracking-[0.08em] text-n-brand"
            >
              {{ $t('SIDEBAR.AUDIENCES') }}
            </p>
            <p class="mb-0 text-2xl font-semibold text-n-brand">
              {{ audienceSegments.length }}
            </p>
          </div>
        </div>
      </section>

      <section
        v-if="audienceSegments.length"
        class="overflow-hidden rounded-3xl bg-n-surface-1 outline outline-1 outline-n-container shadow-sm"
      >
        <BaseTable :headers="tableHeaders" :items="audienceSegments">
          <template #row="{ items }">
            <BaseTableRow
              v-for="segment in items"
              :key="segment.id"
              :item="segment"
            >
              <template #default>
                <BaseTableCell class="max-w-0">
                  <div class="flex flex-col gap-1 min-w-0">
                    <span class="block truncate text-heading-3 text-n-slate-12">
                      {{ segment.name }}
                    </span>
                    <p class="text-body-main text-n-slate-11">
                      {{ $t('OUTBOUND_WORKSPACE.AUDIENCES.SUBTITLE') }}
                    </p>
                  </div>
                </BaseTableCell>

                <BaseTableCell class="w-32 text-n-slate-11">
                  {{ getFilterCount(segment) }}
                </BaseTableCell>

                <BaseTableCell align="end" class="w-32">
                  <Button
                    :label="$t('OUTBOUND_WORKSPACE.AUDIENCES.OPEN')"
                    size="sm"
                    slate
                    @click="openAudience(segment)"
                  />
                </BaseTableCell>
              </template>
            </BaseTableRow>
          </template>
        </BaseTable>
      </section>

      <section
        v-else
        class="rounded-3xl bg-n-surface-2 p-8 outline outline-1 outline-n-container shadow-sm"
      >
        <div class="max-w-2xl">
          <h2 class="mb-2 text-lg font-semibold text-n-slate-12">
            {{ $t('OUTBOUND_WORKSPACE.AUDIENCES.EMPTY') }}
          </h2>
          <p class="mb-4 text-sm leading-6 text-n-slate-11">
            {{ $t('OUTBOUND_WORKSPACE.AUDIENCES.DESCRIPTION') }}
          </p>
          <Button
            :label="$t('OUTBOUND_WORKSPACE.AUDIENCES.MANAGE_CONTACTS')"
            size="sm"
            @click="openContacts"
          />
        </div>
      </section>
    </div>
  </OutboundWorkspaceLayout>
</template>
