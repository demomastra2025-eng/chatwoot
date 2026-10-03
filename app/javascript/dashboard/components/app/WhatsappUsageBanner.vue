<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useDocumentVisibility, useIntervalFn } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
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
const isCategoryBreakdownOpen = ref(false);
const isCategoryBreakdownPinned = ref(false);
const isCategoryBreakdownHovered = ref(false);
const isCategoryBreakdownFocused = ref(false);
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

const categoryDefinitions = [
  { category: 'service', labelKey: 'WHATSAPP_USAGE.CATEGORY_SERVICE' },
  { category: 'utility', labelKey: 'WHATSAPP_USAGE.CATEGORY_UTILITY' },
  { category: 'marketing', labelKey: 'WHATSAPP_USAGE.CATEGORY_MARKETING' },
  { category: 'authentication', labelKey: 'WHATSAPP_USAGE.CATEGORY_AUTH' },
  {
    category: 'authentication-international',
    labelKey: 'WHATSAPP_USAGE.CATEGORY_AUTH_INTERNATIONAL',
  },
  {
    category: 'referral_conversion',
    labelKey: 'WHATSAPP_USAGE.CATEGORY_REFERRAL_CONVERSION',
  },
  { category: 'unknown', labelKey: 'WHATSAPP_USAGE.CATEGORY_UNKNOWN' },
];
const alwaysVisibleCategories = new Set([
  'service',
  'utility',
  'marketing',
  'unknown',
]);
const categoryCountFields = [
  'delivered_count',
  'chargeable_count',
  'free_count',
  'unknown_billable_count',
];

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
const formattedFreeQuotaCount = computed(() =>
  formatCount(usage.value?.free_service_quota_count)
);
const formattedFreeQuotaLimit = computed(() =>
  formatCount(usage.value?.free_service_quota_limit_per_phone)
);
const freeQuotaHistoryStatus = computed(() =>
  usage.value?.free_service_quota_complete === true
    ? t('WHATSAPP_USAGE.HISTORY_COMPLETE')
    : t('WHATSAPP_USAGE.HISTORY_INCOMPLETE')
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
const formattedFreeQuotaByPhone = computed(() => {
  return (
    connectedPhones.value
      .map((phone, index) => {
        const digits = String(phone?.phone_number || '').replace(/\D/g, '');
        const label =
          digits.length > 4 ? `…${digits.slice(-4)}` : String(index + 1);
        return t('WHATSAPP_USAGE.FREE_QUOTA_BY_PHONE', {
          phone: label,
          count: formatCount(phone?.free_service_quota_count),
          limit: formatCount(phone?.free_service_quota_limit),
        });
      })
      .join('; ') || t('WHATSAPP_USAGE.VALUE_UNAVAILABLE')
  );
});
const formattedTemplateCount = computed(() =>
  formatCount(usage.value?.template_delivered_count)
);
const formattedUnpricedCount = computed(() =>
  formatCount(usage.value?.unpriced_billable_count)
);
const formattedUnknownBillableCount = computed(() =>
  formatCount(usage.value?.unknown_billable_count)
);
const categoryRowsByKey = computed(() => {
  const rows = usage.value?.category_breakdown;
  if (!Array.isArray(rows)) return null;

  return new Map(
    rows
      .filter(row => row && typeof row.category === 'string')
      .map(row => [row.category, row])
  );
});
const categoryBreakdownComplete = computed(() => {
  const rowsByKey = categoryRowsByKey.value;
  if (!rowsByKey) return false;

  return categoryDefinitions.every(({ category }) => {
    const row = rowsByKey.get(category);
    return (
      row &&
      categoryCountFields.every(field => toFiniteNumber(row[field]) !== null)
    );
  });
});
const categoryBreakdownRows = computed(() => {
  const rowsByKey = categoryRowsByKey.value;
  if (!rowsByKey) return null;

  return categoryDefinitions
    .filter(({ category }) => {
      if (alwaysVisibleCategories.has(category)) return true;
      const row = rowsByKey.get(category);
      return categoryCountFields.some(
        field => toFiniteNumber(row?.[field]) > 0
      );
    })
    .map(({ category, labelKey }) => {
      const row = rowsByKey.get(category);
      return {
        category,
        labelKey,
        deliveredCount: formatCount(row?.delivered_count),
        chargeableCount: formatCount(row?.chargeable_count),
        freeCount: formatCount(row?.free_count),
        unknownBillableCount: formatCount(row?.unknown_billable_count),
      };
    });
});
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
    data.free_service_quota_complete !== true ||
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
    !categoryBreakdownComplete.value ||
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
    templateCount: formattedTemplateCount.value,
    unpricedCount: formattedUnpricedCount.value,
    unknownCount: formattedUnknownBillableCount.value,
    freeQuotaCount: formattedFreeQuotaCount.value,
    freeQuotaByPhone: formattedFreeQuotaByPhone.value,
    freeQuotaHistoryStatus: freeQuotaHistoryStatus.value,
  });
});

const closeCategoryBreakdown = () => {
  isCategoryBreakdownOpen.value = false;
  isCategoryBreakdownPinned.value = false;
  isCategoryBreakdownHovered.value = false;
  isCategoryBreakdownFocused.value = false;
};

const handleDocumentKeydown = event => {
  if (event.key === 'Escape' && isCategoryBreakdownOpen.value) {
    event.preventDefault();
    closeCategoryBreakdown();
  }
};

const syncCategoryBreakdownVisibility = () => {
  isCategoryBreakdownOpen.value =
    isCategoryBreakdownPinned.value ||
    isCategoryBreakdownHovered.value ||
    isCategoryBreakdownFocused.value;
};

const toggleCategoryBreakdown = () => {
  if (isCategoryBreakdownPinned.value) {
    closeCategoryBreakdown();
    return;
  }

  isCategoryBreakdownPinned.value = true;
  isCategoryBreakdownOpen.value = true;
};

const handleCategoryBreakdownMouseEnter = () => {
  isCategoryBreakdownHovered.value = true;
  isCategoryBreakdownOpen.value = true;
};

const handleCategoryBreakdownMouseLeave = () => {
  isCategoryBreakdownHovered.value = false;
  syncCategoryBreakdownVisibility();
};

const handleCategoryBreakdownFocusIn = () => {
  isCategoryBreakdownFocused.value = true;
  isCategoryBreakdownOpen.value = true;
};

const handleCategoryBreakdownFocusOut = event => {
  if (event.currentTarget.contains(event.relatedTarget)) return;

  isCategoryBreakdownFocused.value = false;
  isCategoryBreakdownPinned.value = false;
  syncCategoryBreakdownVisibility();
};

const handleCategoryBreakdownClickOutside = () => {
  if (isCategoryBreakdownOpen.value) closeCategoryBreakdown();
};

const currentUtcMonth = () => new Date().toISOString().slice(0, 7);
const isUsageMonthStale = () =>
  Boolean(usage.value?.month) && usage.value.month !== currentUtcMonth();

const syncUtcDay = () => {
  const today = currentUtcDay();
  if (today === utcDay.value) return false;

  utcDay.value = today;
  requestGeneration += 1;
  requestInProgress.value = false;
  lastFetchedAt = 0;
  usage.value = null;
  isDismissed.value = false;
  closeCategoryBreakdown();
  return true;
};

function scheduleUtcDayBoundaryRefresh(refresh) {
  if (utcDayBoundaryTimeout) clearTimeout(utcDayBoundaryTimeout);

  const now = new Date();
  const nextUtcDayStart = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + 1
  );
  const delay = Math.min(
    Math.max(0, nextUtcDayStart - now.getTime()),
    MAX_TIMEOUT_DELAY
  );
  utcDayBoundaryTimeout = setTimeout(() => {
    utcDayBoundaryTimeout = null;
    if (syncUtcDay()) refresh();
    scheduleUtcDayBoundaryRefresh(refresh);
  }, delay);
}

const setUsage = payload => {
  usage.value = payload;
  const key = storageKey.value;
  isDismissed.value = key ? LocalStorage.get(key) === true : false;
};

const fetchUsage = async ({ force = false } = {}) => {
  const utcDayChanged = syncUtcDay();
  if (utcDayChanged) {
    scheduleUtcDayBoundaryRefresh(() => fetchUsage({ force: true }));
  }

  const requestedAccountId = Number(accountId.value);
  if (
    !isAdmin.value ||
    !Number.isInteger(requestedAccountId) ||
    !requestedAccountId
  ) {
    usage.value = null;
    isDismissed.value = false;
    closeCategoryBreakdown();
    return;
  }

  const usageMonthChanged = isUsageMonthStale();
  const shouldForce = force || utcDayChanged;

  if (accessDenied.value) return;
  if (isDismissed.value && !shouldForce && !usageMonthChanged) return;
  if (requestInProgress.value) return;
  if (
    !shouldForce &&
    !usageMonthChanged &&
    Date.now() - lastFetchedAt < 30_000
  ) {
    return;
  }

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
      closeCategoryBreakdown();
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
      closeCategoryBreakdown();
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
  closeCategoryBreakdown();
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
    closeCategoryBreakdown();

    accessDenied.value = false;
    hasNoCloudPhones.value = false;
    if (nextAccountId && nextIsAdmin) fetchUsage({ force: true });
  },
  { immediate: true, flush: 'sync' }
);

onMounted(() => {
  window.addEventListener('focus', onWindowFocus);
  document.addEventListener('visibilitychange', onVisibilityChange);
  document.addEventListener('keydown', handleDocumentKeydown);
  scheduleUtcDayBoundaryRefresh(() => fetchUsage({ force: true }));
});

onUnmounted(() => {
  requestGeneration += 1;
  window.removeEventListener('focus', onWindowFocus);
  document.removeEventListener('visibilitychange', onVisibilityChange);
  document.removeEventListener('keydown', handleDocumentKeydown);
  if (utcDayBoundaryTimeout) clearTimeout(utcDayBoundaryTimeout);
});
</script>

<template>
  <section
    v-if="shouldShowBanner"
    role="status"
    aria-live="polite"
    class="flex items-center justify-between gap-3 border-y border-[#ffd9d9] bg-[#fff1f1] px-4 py-1.5 text-n-ruby-12 dark:border-[#704040] dark:bg-[#3b2222]"
    @keydown.esc.stop.prevent="closeCategoryBreakdown"
  >
    <div class="min-w-0 flex-1">
      <div
        v-on-click-outside="handleCategoryBreakdownClickOutside"
        class="relative min-w-0"
        data-testid="whatsapp-usage-breakdown-wrapper"
        @mouseenter="handleCategoryBreakdownMouseEnter"
        @mouseleave="handleCategoryBreakdownMouseLeave"
        @focusin="handleCategoryBreakdownFocusIn"
        @focusout="handleCategoryBreakdownFocusOut"
      >
        <button
          type="button"
          class="flex w-full min-w-0 items-center gap-1 rounded text-left text-[11px] font-medium leading-4 hover:opacity-90 focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-ruby-9 sm:text-xs"
          :aria-label="
            t('WHATSAPP_USAGE.BREAKDOWN_TRIGGER', {
              count: formattedDeliveredCount,
            })
          "
          :aria-expanded="isCategoryBreakdownOpen"
          aria-controls="whatsapp-usage-breakdown"
          data-testid="whatsapp-usage-breakdown-trigger"
          @click.stop="toggleCategoryBreakdown"
        >
          <span
            class="min-w-0 flex-1 break-words"
            data-testid="whatsapp-usage-title"
          >
            {{
              t('WHATSAPP_USAGE.BANNER_TITLE', {
                deliveredCount: formattedDeliveredCount,
                amount:
                  formattedAmount || t('WHATSAPP_USAGE.ESTIMATE_UNAVAILABLE'),
              })
            }}
          </span>
          <i
            class="i-lucide-info size-3.5 shrink-0 text-n-ruby-11"
            aria-hidden="true"
          />
        </button>
        <div
          v-if="isCategoryBreakdownOpen"
          id="whatsapp-usage-breakdown"
          role="region"
          tabindex="0"
          :aria-label="t('WHATSAPP_USAGE.BREAKDOWN_TITLE')"
          class="absolute left-0 top-full z-50 max-h-72 w-72 max-w-[calc(100vw-2rem)] overflow-y-auto rounded-lg bg-n-alpha-3 p-3 text-n-slate-12 shadow-lg outline outline-1 outline-n-weak backdrop-blur-[50px]"
          data-testid="whatsapp-usage-breakdown"
        >
          <p class="m-0 mb-2 text-xs font-medium">
            {{ t('WHATSAPP_USAGE.BREAKDOWN_TITLE') }}
          </p>
          <div v-if="categoryBreakdownRows" class="flex flex-col gap-2">
            <div
              v-for="row in categoryBreakdownRows"
              :key="row.category"
              class="min-w-0"
            >
              <div
                class="flex items-baseline justify-between gap-2 text-xs font-medium"
              >
                <span class="min-w-0">{{ t(row.labelKey) }}</span>
                <span class="shrink-0">
                  {{
                    t('WHATSAPP_USAGE.CATEGORY_DELIVERED', {
                      count: row.deliveredCount,
                    })
                  }}
                </span>
              </div>
              <p class="m-0 mt-0.5 text-[11px] leading-4 text-n-slate-11">
                {{
                  t('WHATSAPP_USAGE.CATEGORY_BILLABILITY', {
                    chargeable: row.chargeableCount,
                    free: row.freeCount,
                    unknown: row.unknownBillableCount,
                  })
                }}
              </p>
            </div>
          </div>
          <p v-else class="m-0 text-xs text-n-slate-11">
            {{ t('WHATSAPP_USAGE.CATEGORY_BREAKDOWN_UNAVAILABLE') }}
          </p>
          <p
            class="m-0 mt-2 border-t border-n-weak pt-2 text-[11px] leading-4 text-n-slate-11"
          >
            {{ t('WHATSAPP_USAGE.CATEGORY_BREAKDOWN_NOTE') }}
          </p>
          <p class="m-0 mt-2 text-[11px] leading-4 text-n-slate-11">
            {{ bannerTooltip }}
          </p>
        </div>
      </div>
      <div
        class="mt-0.5 flex min-w-0 items-baseline gap-2 text-[10px] leading-[14px] sm:text-[11px]"
      >
        <p class="m-0 min-w-0 flex-1 truncate whitespace-nowrap">
          {{ freeQuotaSummary }}
        </p>
        <span
          v-if="isEstimateIncomplete"
          class="shrink-0 whitespace-nowrap text-[10px] font-medium leading-[14px] sm:text-[11px]"
        >
          {{ t('WHATSAPP_USAGE.ESTIMATE_INCOMPLETE') }}
        </span>
      </div>
    </div>
    <button
      type="button"
      class="grid size-8 shrink-0 place-items-center rounded-md text-n-ruby-11 hover:bg-[#ffd9d9] dark:hover:bg-[#704040] focus-visible:outline focus-visible:outline-2 focus-visible:outline-n-ruby-9"
      :aria-label="t('WHATSAPP_USAGE.DISMISS')"
      :title="t('WHATSAPP_USAGE.DISMISS')"
      @click="dismissBanner"
    >
      <i class="i-lucide-x size-4" aria-hidden="true" />
    </button>
  </section>
</template>
