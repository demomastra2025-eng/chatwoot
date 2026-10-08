<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAdmin } from 'dashboard/composables/useAdmin';
import StorageAPI from 'dashboard/api/storage';
import Banner from 'dashboard/components/ui/Banner.vue';

const CACHE_TTL = 15 * 60 * 1000;
const DISMISSAL_TTL = 24 * 60 * 60 * 1000;
const USAGE_REFRESH_INTERVAL = 15 * 60 * 1000;
const { t } = useI18n();
const router = useRouter();
const { accountId } = useAccount();
const { isAdmin } = useAdmin();
const usage = ref(null);
const dismissal = ref(null);
const clock = ref(Date.now());
const usageByAccount = new Map();
let requestGeneration = 0;
let clockTimer;

const usagePercent = computed(() => Number(usage.value?.usage_percent) || 0);
const level = computed(() => {
  if (usage.value?.unlimited || usagePercent.value < 80) return 'normal';
  return usagePercent.value >= 95 ? 'critical' : 'warning';
});
const shouldShow = computed(() => {
  const now = clock.value;
  if (!isAdmin.value || level.value === 'normal') return false;
  return !dismissal.value || now >= dismissal.value.until;
});
const bannerMessage = computed(() =>
  t(`STORAGE.ALERTS.GLOBAL_${level.value.toUpperCase()}`, {
    percentage: usagePercent.value,
  })
);

const readDismissal = id => {
  try {
    const saved = window.localStorage.getItem(`storage-alert:${id}`);
    const parsed = saved ? JSON.parse(saved) : null;
    return parsed && Number(parsed.until) > Date.now() ? parsed : null;
  } catch {
    return null;
  }
};

const fetchUsage = async id => {
  requestGeneration += 1;
  const generation = requestGeneration;
  const cacheKey = String(id);
  const cached = usageByAccount.get(cacheKey);
  usage.value = cached?.data || null;
  if (cached && Date.now() - cached.fetchedAt < CACHE_TTL) return;

  try {
    // The server returns its cached physical breakdown; this is requested once per account
    // change and never on ordinary dashboard route transitions.
    const response = await StorageAPI.getStorage();
    if (generation !== requestGeneration) return;
    const data = response?.data?.storage;
    usage.value = data || null;
    if (data && !data.calculating) {
      usageByAccount.set(cacheKey, { data, fetchedAt: Date.now() });
    }
  } catch {
    if (generation === requestGeneration && !cached) usage.value = null;
  }
};

watch(
  [accountId, isAdmin],
  ([id, admin]) => {
    requestGeneration += 1;
    usage.value = null;
    dismissal.value = null;
    if (!id || !admin) return;
    dismissal.value = readDismissal(id);
    fetchUsage(id);
  },
  { immediate: true }
);

const openStorage = () => {
  router.push({
    name: 'storage_settings_index',
    params: { accountId: accountId.value },
  });
};

const dismiss = () => {
  const value = { level: level.value, until: Date.now() + DISMISSAL_TTL };
  dismissal.value = value;
  try {
    window.localStorage.setItem(
      `storage-alert:${accountId.value}`,
      JSON.stringify(value)
    );
  } catch {
    // Keep the dismissal for this app session when browser storage is unavailable.
  }
};

clockTimer = window.setInterval(() => {
  clock.value = Date.now();
}, 60 * 1000);
const usageRefreshTimer = window.setInterval(() => {
  if (isAdmin.value && accountId.value) fetchUsage(accountId.value);
}, USAGE_REFRESH_INTERVAL);
onBeforeUnmount(() => {
  requestGeneration += 1;
  window.clearInterval(clockTimer);
  window.clearInterval(usageRefreshTimer);
});
</script>

<template>
  <Banner
    v-if="shouldShow"
    data-testid="storage-usage-banner"
    :color-scheme="level === 'critical' ? 'alert' : 'warning'"
    :banner-message="bannerMessage"
    :action-button-label="t('STORAGE.ALERTS.OPEN')"
    has-action-button
    has-close-button
    @primary-action="openStorage"
    @close="dismiss"
  />
</template>
