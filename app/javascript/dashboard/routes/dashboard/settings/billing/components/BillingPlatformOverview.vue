<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { formatBytes } from 'shared/helpers/FileHelper';
import BillingOverviewAPI from 'dashboard/api/billingOverview';
import ButtonV4 from 'next/button/Button.vue';
import BillingCard from './BillingCard.vue';
import BillingMeter from './BillingMeter.vue';
import DetailItem from './DetailItem.vue';

const emit = defineEmits(['loaded']);
const { t, locale } = useI18n();
const overview = ref(null);
const isLoading = ref(true);
const hasError = ref(false);

const subscription = computed(() => overview.value?.subscription);
const billingAccount = computed(() => overview.value?.billing_account);
const planName = computed(() => subscription.value?.plan?.name || '—');
const subscriptionStatus = computed(() => {
  const labels = {
    incomplete: t('BILLING_SETTINGS.PLATFORM.STATUSES.INCOMPLETE'),
    trialing: t('BILLING_SETTINGS.PLATFORM.STATUSES.TRIALING'),
    active: t('BILLING_SETTINGS.PLATFORM.STATUSES.ACTIVE'),
    past_due: t('BILLING_SETTINGS.PLATFORM.STATUSES.PAST_DUE'),
    grace_period: t('BILLING_SETTINGS.PLATFORM.STATUSES.GRACE_PERIOD'),
    suspended: t('BILLING_SETTINGS.PLATFORM.STATUSES.SUSPENDED'),
    canceled: t('BILLING_SETTINGS.PLATFORM.STATUSES.CANCELED'),
  };
  return labels[subscription.value?.status] || '—';
});
const renewalDate = computed(() => {
  const value = subscription.value?.current_period_ends_at;
  return value
    ? new Intl.DateTimeFormat(locale.value).format(new Date(value))
    : '—';
});
const limits = computed(() =>
  (overview.value?.limits || []).map(limit => {
    const storage = limit.key === 'storage_bytes';
    const formatter = value => (storage ? formatBytes(value) : `${value}`);
    const title = storage
      ? t('BILLING_SETTINGS.PLATFORM.LIMITS.STORAGE_BYTES')
      : t('BILLING_SETTINGS.PLATFORM.LIMITS.AGENTS');
    const sourceLabel =
      limit.source === 'billing_allocation'
        ? t('BILLING_SETTINGS.PLATFORM.SOURCE.BILLING_ALLOCATION')
        : t('BILLING_SETTINGS.PLATFORM.SOURCE.LEGACY');
    return {
      ...limit,
      title,
      sourceLabel,
      totalCount: limit.value,
      displayConsumed: formatter(limit.consumed),
      displayTotal: limit.unlimited
        ? t('BILLING_SETTINGS.UNLIMITED')
        : formatter(limit.value),
    };
  })
);

const fetchOverview = async () => {
  isLoading.value = true;
  hasError.value = false;
  try {
    const { data } = await BillingOverviewAPI.get();
    overview.value = data;
    emit('loaded', data.configured);
  } catch {
    hasError.value = true;
  } finally {
    isLoading.value = false;
  }
};

onMounted(fetchOverview);
</script>

<template>
  <section class="grid gap-4 mb-4">
    <BillingCard
      v-if="isLoading"
      :title="$t('BILLING_SETTINGS.PLATFORM.TITLE')"
      :description="$t('BILLING_SETTINGS.PLATFORM.LOADING')"
    />

    <BillingCard
      v-else-if="hasError"
      :title="$t('BILLING_SETTINGS.PLATFORM.TITLE')"
      :description="$t('BILLING_SETTINGS.PLATFORM.ERROR')"
    >
      <template #action>
        <ButtonV4 sm slate @click="fetchOverview">
          {{ $t('BILLING_SETTINGS.PLATFORM.RETRY') }}
        </ButtonV4>
      </template>
    </BillingCard>

    <BillingCard
      v-else-if="!overview.configured"
      :title="$t('BILLING_SETTINGS.PLATFORM.TITLE')"
      :description="$t('BILLING_SETTINGS.PLATFORM.NOT_CONFIGURED')"
    />

    <template v-else>
      <BillingCard
        v-if="billingAccount"
        :title="$t('BILLING_SETTINGS.PLATFORM.ORGANIZATION')"
        :description="$t('BILLING_SETTINGS.PLATFORM.ORGANIZATION_DESCRIPTION')"
      >
        <div
          class="grid grid-cols-1 gap-2 sm:grid-cols-3 divide-x divide-n-weak"
        >
          <DetailItem
            :label="$t('BILLING_SETTINGS.PLATFORM.NAME')"
            :value="billingAccount.name"
          />
          <DetailItem
            :label="$t('BILLING_SETTINGS.PLATFORM.WORKSPACES')"
            :value="`${billingAccount.workspace_count}`"
          />
          <DetailItem
            :label="$t('BILLING_SETTINGS.PLATFORM.UNIQUE_USERS')"
            :value="`${billingAccount.unique_user_count}`"
          />
        </div>
      </BillingCard>

      <BillingCard
        :title="$t('BILLING_SETTINGS.PLATFORM.SUBSCRIPTION')"
        :description="$t('BILLING_SETTINGS.PLATFORM.READ_ONLY')"
      >
        <div
          class="grid grid-cols-1 gap-2 sm:grid-cols-3 divide-x divide-n-weak"
        >
          <DetailItem
            :label="$t('BILLING_SETTINGS.CURRENT_PLAN.TITLE')"
            :value="planName"
          />
          <DetailItem
            :label="$t('BILLING_SETTINGS.PLATFORM.STATUS')"
            :value="subscriptionStatus"
          />
          <DetailItem
            :label="$t('BILLING_SETTINGS.CURRENT_PLAN.RENEWS_ON')"
            :value="renewalDate"
          />
        </div>
      </BillingCard>

      <BillingCard
        :title="$t('BILLING_SETTINGS.PLATFORM.USAGE')"
        :description="$t('BILLING_SETTINGS.PLATFORM.USAGE_DESCRIPTION')"
      >
        <div v-for="limit in limits" :key="limit.key" class="px-5">
          <BillingMeter v-bind="limit" />
          <p class="mt-1 text-xs text-n-slate-9">
            {{ limit.sourceLabel }}
          </p>
        </div>
      </BillingCard>
    </template>
  </section>
</template>
