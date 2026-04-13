<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import CampaignsAPI from 'dashboard/api/campaigns';
import { useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  selectedCampaign: {
    type: Object,
    default: null,
  },
});

const { locale, t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const analytics = ref(null);
const isLoading = ref(false);
const isRetrying = ref(false);
const isRestarting = ref(false);
const isResuming = ref(false);

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
      key: 'coverage',
      label: t('CAMPAIGN.ANALYTICS.STATS.COVERAGE'),
      value: analytics.value?.coverage_rate || 0,
    },
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

const latestRun = computed(() => analytics.value?.latest_run || null);
const recentRuns = computed(() => analytics.value?.recent_runs || []);
const historicalRuns = computed(() =>
  recentRuns.value.filter(run => run.id !== latestRun.value?.id)
);
const isCancelledCampaign = computed(
  () =>
    analytics.value?.campaign_status === 'cancelled' ||
    props.selectedCampaign?.campaign_status === 'cancelled'
);
const hasRetryableFailures = computed(() => {
  if (
    !latestRun.value ||
    latestRun.value.status === 'running' ||
    isCancelledCampaign.value
  ) {
    return false;
  }

  return (
    (latestRun.value.failed_count || 0) + (latestRun.value.skipped_count || 0) >
    0
  );
});
const canRestartCampaign = computed(() =>
  ['failed', 'cancelled'].includes(
    analytics.value?.campaign_status || props.selectedCampaign?.campaign_status
  )
);
const canResumeCampaign = computed(() => {
  const status =
    analytics.value?.campaign_status || props.selectedCampaign?.campaign_status;

  return (
    ['failed', 'cancelled'].includes(status) &&
    (latestRun.value?.resumable_contacts_count || 0) > 0
  );
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

async function retryFailedDeliveries() {
  if (
    !props.selectedCampaign?.id ||
    isRetrying.value ||
    !hasRetryableFailures.value
  ) {
    return;
  }

  isRetrying.value = true;

  try {
    const { data } = await CampaignsAPI.retryFailed(props.selectedCampaign.id);
    analytics.value = data;
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Keep the current analytics state on retry failure.
  } finally {
    isRetrying.value = false;
  }
}

async function restartCampaign() {
  if (
    !props.selectedCampaign?.id ||
    isRestarting.value ||
    !canRestartCampaign.value
  ) {
    return;
  }

  isRestarting.value = true;

  try {
    const { data } = await CampaignsAPI.restart(props.selectedCampaign.id);
    analytics.value = data;
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Keep the current analytics state on restart failure.
  } finally {
    isRestarting.value = false;
  }
}

async function resumeCampaign() {
  if (
    !props.selectedCampaign?.id ||
    isResuming.value ||
    !canResumeCampaign.value
  ) {
    return;
  }

  isResuming.value = true;

  try {
    const { data } = await CampaignsAPI.resume(props.selectedCampaign.id);
    analytics.value = data;
    await store.dispatch('campaigns/get');
  } catch (error) {
    // Keep the current analytics state on resume failure.
  } finally {
    isResuming.value = false;
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

const formatPercent = value => `${formatNumber(value)}%`;

const formatStatValue = stat => {
  if (stat.key === 'coverage') {
    return formatPercent(stat.value);
  }

  return formatNumber(stat.value);
};

const formatRunReference = value => {
  if (!value && value !== 0) return '—';

  return `#${value}`;
};

const formatDuration = value => {
  if (!value && value !== 0) return '—';

  if (value < 60) {
    return t('CAMPAIGN.ANALYTICS.RUNS.DURATION_SECONDS', { count: value });
  }

  const minutes = Math.floor(value / 60);
  const seconds = value % 60;

  if (!seconds) {
    return t('CAMPAIGN.ANALYTICS.RUNS.DURATION_MINUTES', { count: minutes });
  }

  return t('CAMPAIGN.ANALYTICS.RUNS.DURATION_MINUTES_SECONDS', {
    minutes,
    seconds,
  });
};

const runStatusClasses = status => {
  if (status === 'completed') {
    return 'bg-n-teal-3 text-n-teal-11';
  }

  if (status === 'failed') {
    return 'bg-n-ruby-3 text-n-ruby-11';
  }

  if (status === 'running') {
    return 'bg-n-blue-3 text-n-blue-11';
  }

  if (status === 'cancelled') {
    return 'bg-n-alpha-2 text-n-slate-11';
  }

  return 'bg-n-alpha-2 text-n-slate-11';
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
      <div class="grid gap-3 md:grid-cols-5">
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
            {{ formatStatValue(stat) }}
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
                {{ formatPercent(analytics.success_rate || 0) }}
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
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.PROCESSED') }}</dt>
                <dd class="font-medium">
                  {{ formatNumber(analytics.processed_contacts_count || 0) }}
                </dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.ATTEMPTS') }}</dt>
                <dd class="font-medium">
                  {{ formatNumber(analytics.delivery_attempts_count || 0) }}
                </dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.NOT_SENT') }}</dt>
                <dd class="font-medium">
                  {{ formatNumber(analytics.not_sent_count) }}
                </dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt>{{ t('CAMPAIGN.ANALYTICS.SUMMARY.COVERAGE') }}</dt>
                <dd class="font-medium">
                  {{ formatPercent(analytics.coverage_rate || 0) }}
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
              {{ t('CAMPAIGN.ANALYTICS.RUNS_TITLE') }}
            </p>
            <p class="mb-3 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.RUNS_SUBTITLE') }}
            </p>

            <div v-if="latestRun" class="space-y-4">
              <div class="flex items-center justify-end gap-2">
                <Button
                  v-if="canResumeCampaign"
                  size="sm"
                  color="slate"
                  variant="faded"
                  :label="t('CAMPAIGN.ANALYTICS.RESUME_CAMPAIGN')"
                  :is-loading="isResuming"
                  :disabled="isResuming || isRetrying || isRestarting"
                  @click="resumeCampaign"
                />
                <Button
                  v-if="hasRetryableFailures"
                  size="sm"
                  color="blue"
                  variant="faded"
                  :label="t('CAMPAIGN.ANALYTICS.RETRY_FAILED')"
                  :is-loading="isRetrying"
                  :disabled="isRetrying || isRestarting || isResuming"
                  @click="retryFailedDeliveries"
                />
                <Button
                  v-if="canRestartCampaign"
                  size="sm"
                  color="blue"
                  variant="faded"
                  :label="t('CAMPAIGN.ANALYTICS.RESTART_CAMPAIGN')"
                  :is-loading="isRestarting"
                  :disabled="isRestarting || isRetrying || isResuming"
                  @click="restartCampaign"
                />
              </div>

              <article class="rounded-2xl border border-n-weak bg-white/70 p-4">
                <div class="mb-3 flex items-start justify-between gap-3">
                  <div>
                    <p class="mb-1 text-sm font-medium text-n-slate-12">
                      {{ t('CAMPAIGN.ANALYTICS.LATEST_RUN') }}
                    </p>
                    <p class="mb-0 text-xs text-n-slate-11">
                      {{ formatDate(latestRun.created_at) }}
                    </p>
                  </div>
                  <span
                    class="rounded-full px-2.5 py-1 text-xs font-medium capitalize"
                    :class="runStatusClasses(latestRun.status)"
                  >
                    {{ latestRun.status }}
                  </span>
                </div>

                <dl class="space-y-2 text-sm text-n-slate-12">
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.STATUS') }}</dt>
                    <dd class="font-medium capitalize">
                      {{ latestRun.status }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.PROGRESS') }}</dt>
                    <dd class="font-medium">
                      {{ formatPercent(latestRun.progress_percentage || 0) }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.PROCESSED') }}</dt>
                    <dd class="font-medium">
                      {{
                        `${formatNumber(latestRun.processed_count)} / ${formatNumber(
                          latestRun.total_count
                        )}`
                      }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.SUCCESSFUL') }}</dt>
                    <dd class="font-medium">
                      {{ formatNumber(latestRun.successful_count) }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.FAILED') }}</dt>
                    <dd class="font-medium">
                      {{
                        formatNumber(
                          (latestRun.failed_count || 0) +
                            (latestRun.skipped_count || 0)
                        )
                      }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.STARTED') }}</dt>
                    <dd class="font-medium">
                      {{ formatDate(latestRun.started_at) }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.COMPLETED') }}</dt>
                    <dd class="font-medium">
                      {{ formatDate(latestRun.completed_at) }}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-3">
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.DURATION') }}</dt>
                    <dd class="font-medium">
                      {{ formatDuration(latestRun.duration_seconds) }}
                    </dd>
                  </div>
                  <div
                    v-if="latestRun.retry_source_run_id"
                    class="flex items-center justify-between gap-3"
                  >
                    <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.RETRY_OF') }}</dt>
                    <dd class="font-medium">
                      {{ formatRunReference(latestRun.retry_source_run_id) }}
                    </dd>
                  </div>
                </dl>

                <p
                  v-if="latestRun.error_message"
                  class="mb-0 mt-3 text-xs text-n-ruby-11"
                >
                  {{ latestRun.error_message }}
                </p>
              </article>

              <div v-if="historicalRuns.length" class="space-y-3">
                <p
                  class="mb-0 text-xs font-medium uppercase tracking-[0.12em] text-n-slate-11"
                >
                  {{ t('CAMPAIGN.ANALYTICS.RECENT_RUNS') }}
                </p>
                <article
                  v-for="run in historicalRuns"
                  :key="run.id"
                  class="rounded-2xl border border-n-weak bg-white/70 px-4 py-3"
                >
                  <div class="mb-2 flex items-center justify-between gap-3">
                    <div>
                      <div class="flex items-center gap-2">
                        <p class="mb-0 text-sm font-medium text-n-slate-12">
                          {{ formatRunReference(run.id) }}
                        </p>
                        <span
                          v-if="run.retry_source_run_id"
                          class="rounded-full bg-n-blue-3 px-2 py-0.5 text-[11px] font-medium text-n-blue-11"
                        >
                          {{ t('CAMPAIGN.ANALYTICS.RUNS.RETRY_RUN') }}
                        </span>
                      </div>
                      <p class="mb-0 mt-1 text-xs text-n-slate-11">
                        {{ formatDate(run.created_at) }}
                      </p>
                    </div>
                    <span
                      class="rounded-full px-2.5 py-1 text-xs font-medium capitalize"
                      :class="runStatusClasses(run.status)"
                    >
                      {{ run.status }}
                    </span>
                  </div>
                  <p class="mb-0 text-xs text-n-slate-11">
                    {{
                      t('CAMPAIGN.ANALYTICS.RUNS.RECENT_SUMMARY', {
                        processed: formatNumber(run.processed_count),
                        total: formatNumber(run.total_count),
                        success: formatNumber(run.successful_count),
                        failed: formatNumber(
                          (run.failed_count || 0) + (run.skipped_count || 0)
                        ),
                      })
                    }}
                  </p>
                  <dl
                    class="mt-3 grid gap-2 text-xs text-n-slate-12 sm:grid-cols-2"
                  >
                    <div class="flex items-center justify-between gap-3">
                      <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.STARTED') }}</dt>
                      <dd class="font-medium">
                        {{ formatDate(run.started_at) }}
                      </dd>
                    </div>
                    <div class="flex items-center justify-between gap-3">
                      <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.COMPLETED') }}</dt>
                      <dd class="font-medium">
                        {{ formatDate(run.completed_at) }}
                      </dd>
                    </div>
                    <div class="flex items-center justify-between gap-3">
                      <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.DURATION') }}</dt>
                      <dd class="font-medium">
                        {{ formatDuration(run.duration_seconds) }}
                      </dd>
                    </div>
                    <div
                      v-if="run.retry_source_run_id"
                      class="flex items-center justify-between gap-3"
                    >
                      <dt>{{ t('CAMPAIGN.ANALYTICS.RUNS.RETRY_OF') }}</dt>
                      <dd class="font-medium">
                        {{ formatRunReference(run.retry_source_run_id) }}
                      </dd>
                    </div>
                  </dl>
                  <p
                    v-if="run.error_message"
                    class="mb-0 mt-3 text-xs text-n-ruby-11"
                  >
                    {{ run.error_message }}
                  </p>
                </article>
              </div>
            </div>
            <p v-else class="mb-0 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.NO_RUNS') }}
            </p>
          </section>

          <section class="rounded-2xl border border-n-weak bg-n-surface-2 p-5">
            <p class="mb-1 text-base font-medium text-n-slate-12">
              {{ t('CAMPAIGN.ANALYTICS.NOT_SENT_TITLE') }}
            </p>
            <p class="mb-3 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.NOT_SENT_SUBTITLE') }}
            </p>

            <div v-if="analytics.not_sent_contacts.length" class="space-y-3">
              <article
                v-for="contact in analytics.not_sent_contacts"
                :key="contact.id"
                class="rounded-2xl border border-n-weak bg-white/70 px-4 py-3"
              >
                <p class="mb-1 text-sm font-medium text-n-slate-12">
                  {{ contact.name }}
                </p>
                <p class="mb-0 text-xs text-n-slate-11">
                  {{ contact.phone_number || contact.email || '—' }}
                </p>
              </article>
            </div>
            <p v-else class="mb-0 text-sm text-n-slate-11">
              {{ t('CAMPAIGN.ANALYTICS.NO_NOT_SENT') }}
            </p>
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
