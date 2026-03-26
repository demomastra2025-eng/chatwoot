<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import CampaignsAPI from 'dashboard/api/campaigns';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  selectedCampaign: {
    type: Object,
    default: null,
  },
});

const { locale, t } = useI18n();

const dialogRef = ref(null);
const analytics = ref(null);
const isLoading = ref(false);

const numberFormatter = computed(
  () => new Intl.NumberFormat(locale.value || 'en')
);

const dateFormatter = computed(
  () =>
    new Intl.DateTimeFormat(locale.value || 'en', {
      dateStyle: 'medium',
      timeStyle: 'short',
    })
);

const stats = computed(() => {
  const totals = analytics.value?.totals || {};

  return [
    {
      key: 'submitted',
      label: t('CAMPAIGN.ANALYTICS.STATS.SUBMITTED'),
      value: totals.submitted || 0,
    },
    {
      key: 'delivered',
      label: t('CAMPAIGN.ANALYTICS.STATS.DELIVERED'),
      value: totals.delivered || 0,
    },
    {
      key: 'read',
      label: t('CAMPAIGN.ANALYTICS.STATS.READ'),
      value: totals.read || 0,
    },
    {
      key: 'failed',
      label: t('CAMPAIGN.ANALYTICS.STATS.FAILED'),
      value: (totals.failed || 0) + (totals.skipped || 0),
    },
  ];
});

async function fetchAnalytics() {
  if (!props.selectedCampaign?.id) return;

  isLoading.value = true;

  try {
    const { data } = await CampaignsAPI.getAnalytics(props.selectedCampaign.id);
    analytics.value = data;
  } catch (error) {
    analytics.value = null;
  } finally {
    isLoading.value = false;
  }
}

const open = async () => {
  dialogRef.value?.open();
  await fetchAnalytics();
};

const close = () => {
  dialogRef.value?.close();
};

const formatNumber = value => numberFormatter.value.format(value || 0);

const formatDate = value => {
  if (!value) return '—';
  return dateFormatter.value.format(new Date(value * 1000));
};

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    width="3xl"
    overflow-y-auto
    :title="selectedCampaign?.title || t('CAMPAIGN.ANALYTICS.TITLE')"
    :description="t('CAMPAIGN.ANALYTICS.DESCRIPTION')"
    :show-confirm-button="false"
    :cancel-button-label="t('CAMPAIGN.ANALYTICS.CLOSE')"
  >
    <div
      v-if="isLoading"
      class="flex min-h-[18rem] items-center justify-center"
    >
      <Spinner />
    </div>

    <div v-else-if="analytics" class="space-y-6">
      <div class="grid gap-3 md:grid-cols-4">
        <article
          v-for="stat in stats"
          :key="stat.key"
          class="rounded-2xl border border-n-weak bg-n-surface-2 px-4 py-4"
        >
          <p
            class="mb-1 text-xs font-medium uppercase tracking-[0.12em] text-n-slate-11"
          >
            {{ stat.label }}
          </p>
          <p class="mb-0 text-2xl font-semibold text-n-slate-12">
            {{ formatNumber(stat.value) }}
          </p>
        </article>
      </div>

      <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <section class="rounded-2xl border border-n-weak bg-n-surface-2 p-5">
          <div class="mb-4 flex items-center justify-between gap-3">
            <div>
              <p class="mb-1 text-base font-medium text-n-slate-12">
                {{ t('CAMPAIGN.ANALYTICS.DELIVERIES_TITLE') }}
              </p>
              <p class="mb-0 text-sm text-n-slate-11">
                {{ t('CAMPAIGN.ANALYTICS.DELIVERIES_SUBTITLE') }}
              </p>
            </div>
            <div class="text-right">
              <p
                class="mb-0 text-xs uppercase tracking-[0.12em] text-n-slate-11"
              >
                {{ t('CAMPAIGN.ANALYTICS.SUCCESS_RATE') }}
              </p>
              <p class="mb-0 text-xl font-semibold text-n-slate-12">
                {{ `${analytics.success_rate}%` }}
              </p>
            </div>
          </div>

          <div class="overflow-hidden rounded-2xl border border-n-weak">
            <table class="min-w-full divide-y divide-n-weak text-sm">
              <thead class="bg-white/80 text-left text-n-slate-11">
                <tr>
                  <th class="px-4 py-3">
                    {{ t('CAMPAIGN.ANALYTICS.TABLE.CONTACT') }}
                  </th>
                  <th class="px-4 py-3">
                    {{ t('CAMPAIGN.ANALYTICS.TABLE.STATUS') }}
                  </th>
                  <th class="px-4 py-3">
                    {{ t('CAMPAIGN.ANALYTICS.TABLE.PROVIDER') }}
                  </th>
                  <th class="px-4 py-3">
                    {{ t('CAMPAIGN.ANALYTICS.TABLE.UPDATED') }}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak bg-white/70 text-n-slate-12">
                <tr v-for="delivery in analytics.deliveries" :key="delivery.id">
                  <td class="px-4 py-3">
                    <p class="mb-0 font-medium">{{ delivery.contact.name }}</p>
                    <p class="mb-0 text-xs text-n-slate-11">
                      {{
                        delivery.target_identifier ||
                        delivery.contact.phone_number
                      }}
                    </p>
                    <p
                      v-if="delivery.error_message"
                      class="mb-0 mt-1 text-xs text-n-ruby-11"
                    >
                      {{ delivery.error_message }}
                    </p>
                  </td>
                  <td class="px-4 py-3 capitalize">
                    {{ delivery.status }}
                  </td>
                  <td class="px-4 py-3">{{ delivery.provider }}</td>
                  <td class="px-4 py-3">
                    {{
                      formatDate(delivery.last_status_at || delivery.updated_at)
                    }}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <aside class="space-y-4">
          <section class="rounded-2xl border border-n-weak bg-n-surface-2 p-5">
            <p class="mb-1 text-base font-medium text-n-slate-12">
              {{ t('CAMPAIGN.ANALYTICS.SUMMARY_TITLE') }}
            </p>
            <p class="mb-3 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.SUMMARY_SUBTITLE') }}
            </p>
            <dl class="space-y-3 text-sm text-n-slate-12">
              <div class="flex items-center justify-between gap-3">
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.AUDIENCE') }}</dt>
                <dd class="font-medium">
                  {{ formatNumber(analytics.audience_size) }}
                </dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.FAILED') }}</dt>
                <dd class="font-medium">
                  {{
                    formatNumber(
                      (analytics.totals.failed || 0) +
                        (analytics.totals.skipped || 0)
                    )
                  }}
                </dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.READ') }}</dt>
                <dd class="font-medium">
                  {{ formatNumber(analytics.totals.read || 0) }}
                </dd>
              </div>
            </dl>
          </section>

          <section class="rounded-2xl border border-n-weak bg-n-surface-2 p-5">
            <p class="mb-1 text-base font-medium text-n-slate-12">
              {{ t('CAMPAIGN.ANALYTICS.ERRORS_TITLE') }}
            </p>
            <p class="mb-3 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.ERRORS_SUBTITLE') }}
            </p>

            <div v-if="analytics.errors.length" class="space-y-3">
              <article
                v-for="error in analytics.errors"
                :key="error.message"
                class="rounded-2xl border border-n-weak bg-white/70 px-4 py-3"
              >
                <p class="mb-1 text-sm font-medium text-n-slate-12">
                  {{ error.message }}
                </p>
                <p class="mb-0 text-xs text-n-slate-11">
                  {{
                    t('CAMPAIGN.ANALYTICS.ERRORS_COUNT', { count: error.count })
                  }}
                </p>
              </article>
            </div>
            <p v-else class="mb-0 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.NO_ERRORS') }}
            </p>
          </section>
        </aside>
      </div>
    </div>

    <div
      v-else
      class="flex min-h-[16rem] items-center justify-center rounded-2xl border border-dashed border-n-weak bg-n-surface-2 px-6 text-center"
    >
      <p class="mb-0 max-w-sm text-sm text-n-slate-11">
        {{ t('CAMPAIGN.ANALYTICS.UNAVAILABLE') }}
      </p>
    </div>
  </Dialog>
</template>
