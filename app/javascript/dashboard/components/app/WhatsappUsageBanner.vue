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

const deliveredCount = computed(() =>
  Number(usage.value?.delivered_count || 0)
);
const templateDeliveredCount = computed(() =>
  Number(usage.value?.template_delivered_count || 0)
);
const unknownCategoryCount = computed(() =>
  Number(usage.value?.unknown_category_delivered_count || 0)
);

const MAX_TIMEOUT_DELAY = 2 ** 31 - 1;

const formatLocale = computed(() =>
  String(locale.value || 'en').replace(/_/g, '-')
);

const numberFormatter = computed(
  () =>
    new Intl.NumberFormat(formatLocale.value, {
      maximumFractionDigits: 0,
    })
);

const formattedAmount = computed(() => {
  const rawAmount = usage.value?.estimated_amount_kzt;
  if (rawAmount === null || rawAmount === undefined || rawAmount === '') {
    return null;
  }

  const amount = Number(rawAmount);
  if (!Number.isFinite(amount)) return null;

  return new Intl.NumberFormat(formatLocale.value, {
    style: 'currency',
    currency: usage.value?.currency || 'KZT',
    maximumFractionDigits: 0,
  }).format(amount);
});

const formattedDeliveredCount = computed(() =>
  numberFormatter.value.format(deliveredCount.value)
);
const formattedTemplateCount = computed(() =>
  numberFormatter.value.format(templateDeliveredCount.value)
);
const formattedUnknownCategoryCount = computed(() =>
  numberFormatter.value.format(unknownCategoryCount.value)
);

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
      return;
    }

    setUsage(payload);
  } catch {
    if (generation === requestGeneration) {
      // Keep endpoint failures and authorization changes from exposing stale data.
      usage.value = null;
      isDismissed.value = false;
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
  [shouldShowBanner, isAdmin, documentVisibility],
  ([isVisible, isCurrentAdmin, visibility]) => {
    if (isVisible && isCurrentAdmin && visibility === 'visible') {
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
    <div class="min-w-0 flex-1" :title="t('WHATSAPP_USAGE.BANNER_TOOLTIP')">
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
      <div class="mt-0.5 text-[11px] leading-4 sm:text-xs">
        <p
          class="m-0 truncate whitespace-nowrap text-[10px] leading-4 sm:text-xs"
        >
          {{
            t('WHATSAPP_USAGE.BANNER_DETAILS', {
              templateCount: formattedTemplateCount,
              unknownCount: formattedUnknownCategoryCount,
            })
          }}
        </p>
        <p
          class="m-0 flex items-center justify-between gap-2 whitespace-nowrap text-[10px] leading-4 sm:text-[11px]"
        >
          <span>{{ t('WHATSAPP_USAGE.TEMPLATE_COSTS_SEPARATE') }}</span>
          <span
            v-if="
              usage.unknown_delivery_timestamp_count > 0 ||
              usage.unknown_category_delivered_count > 0 ||
              usage.unknown_service_billability_count > 0 ||
              usage.coverage_complete === false ||
              usage.service_estimate_complete === false
            "
            class="shrink-0 font-medium"
            :title="t('WHATSAPP_USAGE.BANNER_TOOLTIP')"
          >
            {{ t('WHATSAPP_USAGE.ESTIMATE_INCOMPLETE') }}
          </span>
        </p>
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
