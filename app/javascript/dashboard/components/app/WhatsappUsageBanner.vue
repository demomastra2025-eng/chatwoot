<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useDocumentVisibility, useIntervalFn } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import WhatsappUsageAPI from 'dashboard/api/whatsappUsage';
import { LocalStorage } from 'shared/helpers/localStorage';

const { t, locale } = useI18n();
const { accountId } = useAccount();
const { isAdmin } = useAdmin();

const usage = ref(null);
const isDismissed = ref(false);
const requestInProgress = ref(false);
const accessDenied = ref(false);
const hasNoCloudPhones = ref(false);
let requestGeneration = 0;
let lastFetchedAt = 0;
let monthBoundaryTimeout = null;

const storageKey = computed(() => {
  if (!accountId.value || !usage.value?.month) return null;
  return `${LOCAL_STORAGE_KEYS.DISMISSED_WHATSAPP_USAGE}::${accountId.value}:${usage.value.month}`;
});

const shouldShowBanner = computed(
  () =>
    Boolean(usage.value?.eligible) &&
    Number(usage.value?.official_cloud_phone_count) > 0 &&
    !isDismissed.value
);

const MAX_TIMEOUT_DELAY = 2 ** 31 - 1;

const formatLocale = computed(() =>
  String(locale.value || 'en').replace(/_/g, '-')
);

const toFiniteNumber = value => {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && value.trim() === '') return null;

  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};

const formatCount = value => {
  const count = toFiniteNumber(value);
  if (count === null) return t('WHATSAPP_USAGE.COUNT_UNAVAILABLE');

  return new Intl.NumberFormat(formatLocale.value, {
    maximumFractionDigits: 0,
  }).format(count);
};

const formatKztAmount = value => {
  const amount = toFiniteNumber(value);
  if (amount === null) return null;
  // An explicit zero from the backend does not require currency conversion.
  // Missing amounts remain unavailable rather than being converted to zero.
  if (usage.value?.exchange_rate?.available !== true) {
    const isConfirmedFree =
      amount === 0 &&
      toFiniteNumber(usage.value?.chargeable_message_count) === 0;
    if (!isConfirmedFree) return null;
  }

  return new Intl.NumberFormat(formatLocale.value, {
    style: 'currency',
    currency: 'KZT',
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(amount);
};

const formattedAmount = computed(() =>
  formatKztAmount(usage.value?.estimated_amount_kzt)
);
const formattedServiceAmount = computed(
  () =>
    formatKztAmount(usage.value?.estimated_service_amount_kzt) ||
    t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE')
);
const formattedTemplateAmount = computed(
  () =>
    formatKztAmount(usage.value?.estimated_template_amount_kzt) ||
    t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE')
);
const formattedDeliveredCount = computed(() =>
  formatCount(usage.value?.delivered_count)
);
const formattedTemplateCount = computed(() =>
  formatCount(usage.value?.template_delivered_count)
);
const formattedUnpricedCount = computed(() =>
  formatCount(usage.value?.unpriced_billable_count)
);
const formattedUnknownBillableCount = computed(() =>
  formatCount(usage.value?.unknown_billable_count)
);
const formattedRate = computed(() => {
  if (usage.value?.exchange_rate?.available !== true) {
    return t('WHATSAPP_USAGE.RATE_UNAVAILABLE');
  }

  const rate = toFiniteNumber(usage.value.exchange_rate.rate_per_usd);
  if (rate === null) return t('WHATSAPP_USAGE.RATE_UNAVAILABLE');

  return new Intl.NumberFormat(formatLocale.value, {
    maximumFractionDigits: 4,
  }).format(rate);
});

const isEstimateIncomplete = computed(() => {
  const data = usage.value;
  if (!data) return true;
  const requiresExchangeRate =
    toFiniteNumber(data.chargeable_message_count) !== 0;
  const hasExchangeRate =
    data.exchange_rate?.available === true &&
    Boolean(data.exchange_rate?.month) &&
    Boolean(data.exchange_rate?.requested_date) &&
    Boolean(data.exchange_rate?.effective_date) &&
    toFiniteNumber(data.exchange_rate?.rate_per_usd) !== null;

  return (
    data.estimate_complete !== true ||
    data.coverage_complete === false ||
    data.template_costs_included !== true ||
    data.estimated_amount_scope !== 'billable_message_base_rates' ||
    data.volume_discounts_included !== false ||
    (requiresExchangeRate && !hasExchangeRate) ||
    toFiniteNumber(data.delivered_count) === null ||
    toFiniteNumber(data.template_delivered_count) === null ||
    toFiniteNumber(data.chargeable_service_count) === null ||
    toFiniteNumber(data.chargeable_template_count) === null ||
    toFiniteNumber(data.chargeable_message_count) === null ||
    toFiniteNumber(data.unpriced_billable_count) === null ||
    toFiniteNumber(data.unpriced_billable_count) > 0 ||
    toFiniteNumber(data.unknown_billable_count) === null ||
    toFiniteNumber(data.unknown_billable_count) > 0 ||
    formattedServiceAmount.value === t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE') ||
    formattedTemplateAmount.value ===
      t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE') ||
    formattedAmount.value === null
  );
});

const bannerTooltip = computed(() => {
  const rate = usage.value?.exchange_rate;

  return t('WHATSAPP_USAGE.BANNER_TOOLTIP', {
    month: usage.value?.month || t('WHATSAPP_USAGE.VALUE_UNAVAILABLE'),
    rateMonth:
      rate?.month ||
      usage.value?.month ||
      t('WHATSAPP_USAGE.VALUE_UNAVAILABLE'),
    serviceAmount: formattedServiceAmount.value,
    templateAmount: formattedTemplateAmount.value,
    requestedDate:
      rate?.requested_date || t('WHATSAPP_USAGE.VALUE_UNAVAILABLE'),
    effectiveDate:
      rate?.effective_date || t('WHATSAPP_USAGE.VALUE_UNAVAILABLE'),
    rate: formattedRate.value,
    unpricedCount: formattedUnpricedCount.value,
    unknownCount: formattedUnknownBillableCount.value,
  });
});

const currentUtcMonth = () => new Date().toISOString().slice(0, 7);
const isUsageMonthStale = () =>
  Boolean(usage.value?.month) && usage.value.month !== currentUtcMonth();

const setUsage = payload => {
  usage.value = payload;
  const key = storageKey.value;
  isDismissed.value = key ? LocalStorage.get(key) === true : false;
};

const fetchUsage = async ({ force = false } = {}) => {
  const requestedAccountId = Number(accountId.value);
  if (
    !isAdmin.value ||
    !Number.isInteger(requestedAccountId) ||
    !requestedAccountId
  ) {
    usage.value = null;
    isDismissed.value = false;
    return;
  }

  const usageMonthChanged = isUsageMonthStale();

  if (accessDenied.value) return;
  if (isDismissed.value && !force && !usageMonthChanged) return;
  if (requestInProgress.value) return;
  if (!force && !usageMonthChanged && Date.now() - lastFetchedAt < 30_000) {
    return;
  }

  requestGeneration += 1;
  const generation = requestGeneration;
  requestInProgress.value = true;
  lastFetchedAt = Date.now();

  try {
    const response = await WhatsappUsageAPI.getMonthlyUsage(requestedAccountId);
    if (
      generation !== requestGeneration ||
      Number(accountId.value) !== requestedAccountId ||
      !isAdmin.value
    ) {
      return;
    }

    const payload = response?.data?.whatsapp_usage;
    if (
      !payload ||
      payload.eligible !== true ||
      Number(payload.official_cloud_phone_count) <= 0
    ) {
      setUsage(null);
      isDismissed.value = false;
      hasNoCloudPhones.value = true;
      return;
    }

    hasNoCloudPhones.value = false;
    setUsage(payload);
  } catch (error) {
    if (generation === requestGeneration) {
      // Keep endpoint failures and authorization changes from exposing stale data.
      usage.value = null;
      isDismissed.value = false;
      accessDenied.value = [401, 403].includes(error?.response?.status);
    }
  } finally {
    if (generation === requestGeneration) requestInProgress.value = false;
  }
};

const documentVisibility = useDocumentVisibility();
const { pause: pauseUsagePolling, resume: resumeUsagePolling } = useIntervalFn(
  fetchUsage,
  60_000,
  { immediate: false, immediateCallback: false }
);

watch(
  [isDismissed, isAdmin, documentVisibility, accessDenied, hasNoCloudPhones],
  ([dismissed, isCurrentAdmin, visibility, denied, noCloudPhones]) => {
    if (
      !dismissed &&
      isCurrentAdmin &&
      visibility === 'visible' &&
      !denied &&
      !noCloudPhones
    ) {
      resumeUsagePolling();
    } else {
      pauseUsagePolling();
    }
  },
  { immediate: true, flush: 'sync' }
);

const dismissBanner = () => {
  const key = storageKey.value;
  if (!key) return;

  LocalStorage.set(key, true);
  isDismissed.value = true;
};

const onWindowFocus = () => fetchUsage({ force: isUsageMonthStale() });
const onVisibilityChange = () => {
  if (document.visibilityState === 'visible') {
    fetchUsage({ force: isUsageMonthStale() });
  }
};

const scheduleMonthBoundaryRefresh = () => {
  if (monthBoundaryTimeout) clearTimeout(monthBoundaryTimeout);

  const now = new Date();
  const nextMonthStart = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth() + 1,
    1
  );
  const delay = Math.min(
    Math.max(0, nextMonthStart - now.getTime()),
    MAX_TIMEOUT_DELAY
  );
  monthBoundaryTimeout = setTimeout(() => {
    if (Date.now() < nextMonthStart) {
      scheduleMonthBoundaryRefresh();
      return;
    }

    requestGeneration += 1;
    requestInProgress.value = false;
    lastFetchedAt = 0;
    usage.value = null;
    isDismissed.value = false;
    fetchUsage({ force: true });
    scheduleMonthBoundaryRefresh();
  }, delay);
};

watch(
  [accountId, isAdmin],
  ([nextAccountId, nextIsAdmin]) => {
    requestGeneration += 1;
    requestInProgress.value = false;
    lastFetchedAt = 0;
    usage.value = null;
    isDismissed.value = false;

    accessDenied.value = false;
    hasNoCloudPhones.value = false;
    if (nextAccountId && nextIsAdmin) fetchUsage({ force: true });
  },
  { immediate: true, flush: 'sync' }
);

onMounted(() => {
  window.addEventListener('focus', onWindowFocus);
  document.addEventListener('visibilitychange', onVisibilityChange);
  scheduleMonthBoundaryRefresh();
});

onUnmounted(() => {
  requestGeneration += 1;
  window.removeEventListener('focus', onWindowFocus);
  document.removeEventListener('visibilitychange', onVisibilityChange);
  if (monthBoundaryTimeout) clearTimeout(monthBoundaryTimeout);
});
</script>

<template>
  <section
    v-if="shouldShowBanner"
    role="status"
    aria-live="polite"
    class="flex items-start justify-between gap-3 border-y border-n-ruby-5 bg-n-ruby-3 px-4 py-2 text-n-ruby-12"
  >
    <div class="min-w-0 flex-1" :title="bannerTooltip">
      <p
        class="m-0 break-words text-xs font-medium leading-4 sm:text-sm sm:leading-5"
      >
        {{
          t('WHATSAPP_USAGE.BANNER_TITLE', {
            deliveredCount: formattedDeliveredCount,
            amount: formattedAmount || t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE'),
          })
        }}
      </p>
      <div
        class="mt-0.5 flex min-w-0 items-baseline gap-2 text-[11px] leading-4 sm:text-xs"
      >
        <p
          class="m-0 min-w-0 flex-1 truncate whitespace-nowrap text-[10px] leading-4 sm:text-xs"
        >
          {{
            t('WHATSAPP_USAGE.BANNER_DETAILS', {
              templateCount: formattedTemplateCount,
              unpricedCount: formattedUnpricedCount,
              unknownCount: formattedUnknownBillableCount,
            })
          }}
        </p>
        <span
          v-if="isEstimateIncomplete"
          class="shrink-0 whitespace-nowrap text-[10px] font-medium leading-4 sm:text-[11px]"
        >
          {{ t('WHATSAPP_USAGE.ESTIMATE_INCOMPLETE') }}
        </span>
      </div>
    </div>
    <button
      type="button"
      class="-mr-1 -mt-1 grid size-8 shrink-0 place-items-center rounded-md text-lg leading-none text-n-ruby-11 hover:bg-n-ruby-4 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-ruby-9"
      :aria-label="t('WHATSAPP_USAGE.DISMISS')"
      :title="t('WHATSAPP_USAGE.DISMISS')"
      @click="dismissBanner"
    >
      <i class="i-lucide-x size-4" aria-hidden="true" />
    </button>
  </section>
</template>
