<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useDocumentVisibility, useIntervalFn } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import WhatsappUsageAPI from 'dashboard/api/whatsappUsage';
import { LocalStorage } from 'shared/helpers/localStorage';

const { t, locale } = useI18n();
const router = useRouter();
const { accountId } = useAccount();
const { isAdmin } = useAdmin();

const usage = ref(null);
const isDismissed = ref(false);
const requestInProgress = ref(false);
const accessDenied = ref(false);
const hasNoCloudPhones = ref(false);
let requestGeneration = 0;
let lastFetchedAt = 0;
let utcDayBoundaryTimeout = null;
const currentUtcDay = () => new Date().toISOString().slice(0, 10);
const utcDay = ref(currentUtcDay());

const storageKey = computed(() => {
  if (!accountId.value || !utcDay.value) return null;
  return `${LOCAL_STORAGE_KEYS.DISMISSED_WHATSAPP_USAGE}::daily::${accountId.value}:${utcDay.value}`;
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

const displayedRawAmount = computed(() => {
  const withVat = toFiniteNumber(usage.value?.estimated_amount_with_vat_kzt);
  if (withVat !== null) return withVat;
  return usage.value?.estimated_amount_kzt;
});

const formattedAmount = computed(() => formatKztAmount(displayedRawAmount.value));
const formattedBaseAmount = computed(() =>
  formatKztAmount(usage.value?.estimated_amount_kzt)
);
const formattedDeliveredCount = computed(() =>
  formatCount(usage.value?.delivered_count)
);
const formattedFreeQuotaCount = computed(() =>
  formatCount(usage.value?.free_service_quota_count)
);
const formattedFreeQuotaLimit = computed(() =>
  formatCount(usage.value?.free_service_quota_limit_per_phone)
);

const connectedPhones = computed(() => {
  const phones = Array.isArray(usage.value?.phones) ? usage.value.phones : [];
  return phones.filter(phone => phone?.connected === true);
});

const freeQuotaSummary = computed(() => {
  const key =
    connectedPhones.value.length === 1 ||
    (connectedPhones.value.length === 0 &&
      toFiniteNumber(usage.value?.official_cloud_phone_count) === 1)
      ? 'WHATSAPP_USAGE.FREE_QUOTA_SINGLE_SUMMARY'
      : 'WHATSAPP_USAGE.FREE_QUOTA_MULTI_SUMMARY';

  return t(key, {
    count: formattedFreeQuotaCount.value,
    limit: formattedFreeQuotaLimit.value,
  });
});

const consecutiveCount = computed(
  () =>
    toFiniteNumber(
      usage.value?.consecutive_summary?.chargeable_consecutive_count
    ) || 0
);

const formattedConsecutiveOverpayment = computed(() =>
  formatKztAmount(
    usage.value?.consecutive_summary?.estimated_overpayment_with_vat_kzt ??
      usage.value?.consecutive_summary?.estimated_overpayment_kzt
  )
);

const compactSummary = computed(
  () =>
    `${t('WHATSAPP_USAGE.BANNER_TITLE', {
      deliveredCount: formattedDeliveredCount.value,
      amount: formattedAmount.value || t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE'),
    })} · ${freeQuotaSummary.value}`
);

const bannerTooltip = computed(() =>
  t('WHATSAPP_USAGE.BANNER_CLICK_HINT', {
    baseAmount:
      formattedBaseAmount.value || t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE'),
    vatAmount:
       formattedAmount.value || t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE'),
  })
);

const openWhatsappReport = () => {
  if (!accountId.value || !router) return;
  router.push({
    name: 'whatsapp_reports',
    params: { accountId: accountId.value },
  });
};

const syncDismissedState = () => {
  const key = storageKey.value;
  isDismissed.value = key ? Boolean(LocalStorage.get(key)) : false;
};

const syncUtcDay = () => {
  const nextUtcDay = currentUtcDay();
  if (utcDay.value === nextUtcDay) return false;

  utcDay.value = nextUtcDay;
  syncDismissedState();
  return true;
};

const isUsageMonthStale = () => {
  const currentMonth = currentUtcDay().slice(0, 7);
  return Boolean(usage.value?.month && usage.value.month !== currentMonth);
};

const setUsage = payload => {
  usage.value = payload;
  syncUtcDay();
  syncDismissedState();
};

const scheduleUtcDayBoundaryRefresh = callback => {
  if (utcDayBoundaryTimeout) clearTimeout(utcDayBoundaryTimeout);

  const now = new Date();
  const nextUtcMidnight = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + 1
  );
  const delay = Math.max(nextUtcMidnight - now.getTime() + 100, 100);
  if (delay > MAX_TIMEOUT_DELAY) {
    utcDayBoundaryTimeout = setTimeout(() => {
      scheduleUtcDayBoundaryRefresh(callback);
    }, MAX_TIMEOUT_DELAY);
    return;
  }

  utcDayBoundaryTimeout = setTimeout(() => {
    syncUtcDay();
    callback();
    scheduleUtcDayBoundaryRefresh(callback);
  }, delay);
};

const fetchUsage = async ({ force = false } = {}) => {
  const dayChanged = syncUtcDay();
  if (dayChanged) {
    scheduleUtcDayBoundaryRefresh(() => fetchUsage({ force: true }));
  }
  const shouldForce = force || dayChanged || isUsageMonthStale();
  const requestedAccountId = Number(accountId.value);
  if (!requestedAccountId || !isAdmin.value) {
    usage.value = null;
    isDismissed.value = false;
    return;
  }

  if (
    !shouldForce &&
    (requestInProgress.value ||
      isDismissed.value ||
      accessDenied.value ||
      hasNoCloudPhones.value)
  ) {
    return;
  }
  if (!shouldForce && Date.now() - lastFetchedAt < 15_000) return;

  requestGeneration += 1;
  const generation = requestGeneration;
  const requestedUtcDay = utcDay.value;
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
    if (currentUtcDay() !== requestedUtcDay) {
      syncUtcDay();
      scheduleUtcDayBoundaryRefresh(() => fetchUsage({ force: true }));
      fetchUsage({ force: true });
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
  scheduleUtcDayBoundaryRefresh(() => fetchUsage({ force: true }));
});

onUnmounted(() => {
  requestGeneration += 1;
  window.removeEventListener('focus', onWindowFocus);
  document.removeEventListener('visibilitychange', onVisibilityChange);
  if (utcDayBoundaryTimeout) clearTimeout(utcDayBoundaryTimeout);
});
</script>

<template>
  <section
    v-if="shouldShowBanner"
    role="status"
    aria-live="polite"
    class="flex items-center justify-between gap-2 border-b border-n-weak bg-n-solid-2 px-3 py-1 text-n-slate-12"
  >
    <button
      type="button"
      class="group flex min-w-0 flex-1 items-center justify-between gap-2 rounded-md px-2 py-0.5 text-left text-xs transition-colors hover:bg-n-alpha-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
      :title="bannerTooltip"
      data-testid="whatsapp-usage-report-link"
      @click="openWhatsappReport"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5">
        <span class="inline-flex items-center gap-1.5 font-medium text-n-slate-12">
          <i
            class="i-lucide-message-circle size-3.5 shrink-0 text-n-teal-10"
            aria-hidden="true"
          />
          <span data-testid="whatsapp-usage-title">
            {{ compactSummary }}
          </span>
        </span>
        <span
          v-if="consecutiveCount > 0 && formattedConsecutiveOverpayment"
          class="inline-flex items-center gap-1 rounded-full bg-n-amber-3 px-2 py-0.5 text-[11px] font-medium text-n-amber-11"
          data-testid="whatsapp-usage-consecutive-badge"
        >
          <i class="i-lucide-layers size-3 shrink-0" aria-hidden="true" />
          {{
            t('WHATSAPP_USAGE.BANNER_CONSECUTIVE_BADGE', {
              count: formatCount(consecutiveCount),
              amount: formattedConsecutiveOverpayment,
            })
          }}
        </span>
      </div>
      <span
        class="inline-flex shrink-0 items-center gap-1 text-[11px] font-medium text-n-teal-11 group-hover:underline"
      >
        {{ t('WHATSAPP_USAGE.OPEN_REPORT') }}
        <i class="i-lucide-arrow-right size-3" aria-hidden="true" />
      </span>
    </button>
    <button
      type="button"
      class="grid size-6 shrink-0 place-items-center rounded-md p-0 text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-brand"
      :aria-label="t('WHATSAPP_USAGE.DISMISS')"
      :title="t('WHATSAPP_USAGE.DISMISS')"
      @click="dismissBanner"
    >
      <i class="i-lucide-x size-3.5" aria-hidden="true" />
    </button>
  </section>
</template>
