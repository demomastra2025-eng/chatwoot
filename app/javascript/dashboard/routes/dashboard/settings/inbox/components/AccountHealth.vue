<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import ButtonV4 from 'next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  healthData: {
    type: Object,
    default: null,
  },
  isRegisteringWebhook: {
    type: Boolean,
    default: false,
  },
  recoveryData: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['registerWebhook']);

const { t } = useI18n();

const QUALITY_COLORS = {
  GREEN: 'text-n-teal-11',
  YELLOW: 'text-n-amber-11',
  RED: 'text-n-ruby-11',
  UNKNOWN: 'text-n-slate-12',
};

const STATUS_COLORS = {
  APPROVED: 'text-n-teal-11',
  PENDING_REVIEW: 'text-n-amber-11',
  AVAILABLE_WITHOUT_REVIEW: 'text-n-teal-11',
  REJECTED: 'text-n-ruby-9',
  DECLINED: 'text-n-ruby-9',
};

const MODE_COLORS = {
  LIVE: 'text-n-teal-11',
  SANDBOX: 'text-n-slate-11',
};

const healthItems = computed(() => {
  if (!props.healthData) {
    return [];
  }

  const {
    display_phone_number: displayPhoneNumber,
    verified_name: verifiedName,
    name_status: nameStatus,
    quality_rating: qualityRating,
    messaging_limit: messagingLimit,
    account_mode: accountMode,
  } = props.healthData;

  return [
    {
      key: 'displayPhoneNumber',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.DISPLAY_PHONE_NUMBER.LABEL'),
      value: displayPhoneNumber || 'N/A',
      tooltip: t(
        'INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.DISPLAY_PHONE_NUMBER.TOOLTIP'
      ),
      show: true,
    },
    {
      key: 'verifiedName',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.VERIFIED_NAME.LABEL'),
      value: verifiedName || 'N/A',
      tooltip: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.VERIFIED_NAME.TOOLTIP'),
      show: true,
    },
    {
      key: 'displayNameStatus',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.DISPLAY_NAME_STATUS.LABEL'),
      value: nameStatus || 'UNKNOWN',
      tooltip: t(
        'INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.DISPLAY_NAME_STATUS.TOOLTIP'
      ),
      show: true,
      type: 'status',
    },
    {
      key: 'qualityRating',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.QUALITY_RATING.LABEL'),
      value: qualityRating || 'UNKNOWN',
      tooltip: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.QUALITY_RATING.TOOLTIP'),
      show: true,
      type: 'quality',
    },
    {
      key: 'messagingLimit',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.MESSAGING_LIMIT_TIER.LABEL'),
      value: messagingLimit || 'UNKNOWN',
      tooltip: t(
        'INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.MESSAGING_LIMIT_TIER.TOOLTIP'
      ),
      show: true,
      type: 'tier',
    },
    {
      key: 'accountMode',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.ACCOUNT_MODE.LABEL'),
      value: accountMode || 'UNKNOWN',
      tooltip: t('INBOX_MGMT.ACCOUNT_HEALTH.FIELDS.ACCOUNT_MODE.TOOLTIP'),
      show: true,
      type: 'mode',
    },
  ];
});

const handleGoToSettings = () => {
  const { business_id: businessId } = props.healthData || {};

  if (businessId) {
    // WhatsApp Business Manager URL with specific business ID and phone numbers tab
    const whatsappBusinessUrl = `https://business.facebook.com/latest/whatsapp_manager/phone_numbers/?business_id=${businessId}&tab=phone-numbers`;
    window.open(whatsappBusinessUrl, '_blank');
  } else {
    // Fallback to general WhatsApp Business Manager if business_id is not available
    const fallbackUrl = 'https://business.facebook.com/';
    window.open(fallbackUrl, '_blank');
  }
};

const getQualityRatingTextColor = rating =>
  QUALITY_COLORS[rating] || QUALITY_COLORS.UNKNOWN;

const formatTierDisplay = tier =>
  t(`INBOX_MGMT.ACCOUNT_HEALTH.VALUES.TIERS.${tier}`) || tier;

const formatStatusDisplay = status =>
  t(`INBOX_MGMT.ACCOUNT_HEALTH.VALUES.STATUSES.${status}`) || status;

const formatModeDisplay = mode =>
  t(`INBOX_MGMT.ACCOUNT_HEALTH.VALUES.MODES.${mode}`) || mode;

const getModeStatusTextColor = mode => MODE_COLORS[mode] || 'text-n-slate-12';

const getStatusTextColor = status => STATUS_COLORS[status] || 'text-n-slate-12';

const showWebhookSection = computed(
  () => props.healthData?.webhook_configuration !== undefined
);

const webhookUrl = computed(
  () =>
    props.healthData?.webhook_configuration?.whatsapp_business_account ||
    props.healthData?.webhook_configuration?.application
);

const webhookConfigured = computed(() => !!webhookUrl.value);

const webhookUrlMismatch = computed(
  () =>
    webhookConfigured.value &&
    webhookUrl.value !== props.healthData?.expected_webhook_url
);

const recoveryItems = computed(() => {
  const data = props.recoveryData || {};
  const callback = data.webhook_callback_recovery;
  const sync = data.coexistence_sync;
  const lifecycle = data.meta_webhook_lifecycle;
  const lifecycleEventCount = Object.values(lifecycle?.counters || {}).reduce(
    (total, count) => total + Number(count || 0),
    0
  );

  return [
    callback && {
      key: 'callback',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.CALLBACK'),
      value: callback.state,
      detail: callback.last_error,
    },
    sync && {
      key: 'sync',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.COEXISTENCE_SYNC'),
      value: sync.state,
      detail: sync.last_error,
    },
    lifecycle && {
      key: 'lifecycle',
      label: t('INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.LIFECYCLE'),
      value: t('INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.EVENTS', {
        count: lifecycleEventCount,
      }),
      detail: lifecycle.last_event_at,
    },
  ].filter(Boolean);
});

const formatRecoveryState = state =>
  String(state || 'unknown').replaceAll('_', ' ');

const recoveryToneClass = state => {
  const normalizedState = String(state || '');
  if (['resolved', 'completed'].includes(normalizedState)) {
    return 'text-n-teal-11';
  }
  if (
    [
      'failed',
      'history_failed',
      'history_declined',
      'manual_recovery_required',
      'outcome_unknown',
    ].some(failureState => normalizedState.includes(failureState))
  ) {
    return 'text-n-ruby-11';
  }
  return 'text-n-amber-11';
};

const handleRegisterWebhook = () => {
  emit('registerWebhook');
};
</script>

<template>
  <div class="gap-4 mx-6">
    <div
      class="px-5 py-5 space-y-6 rounded-xl outline outline-1 -outline-offset-1 outline-n-weak bg-n-solid-2"
    >
      <div
        class="flex flex-col gap-5 justify-between items-start w-full md:flex-row"
      >
        <div>
          <span class="text-heading-3 text-n-slate-12">
            {{ t('INBOX_MGMT.ACCOUNT_HEALTH.TITLE') }}
          </span>
          <p class="mt-1 text-body-main text-n-slate-11">
            {{ t('INBOX_MGMT.ACCOUNT_HEALTH.DESCRIPTION') }}
          </p>
        </div>
        <ButtonV4
          sm
          solid
          blue
          class="flex-shrink-0"
          @click="handleGoToSettings"
        >
          {{ t('INBOX_MGMT.ACCOUNT_HEALTH.GO_TO_SETTINGS') }}
        </ButtonV4>
      </div>

      <div v-if="healthData" class="grid grid-cols-1 gap-4 xs:grid-cols-2">
        <div
          v-for="item in healthItems"
          :key="item.key"
          class="flex flex-col gap-2 p-4 rounded-lg border border-n-weak bg-n-solid-1"
        >
          <div class="flex gap-2 items-center">
            <span class="text-body-main font-medium text-n-slate-11">
              {{ item.label }}
            </span>
            <Icon
              v-tooltip.top="item.tooltip"
              icon="i-lucide-info"
              class="flex-shrink-0 w-4 h-4 cursor-help text-n-slate-9"
            />
          </div>
          <div class="flex items-center">
            <span
              v-if="item.type === 'quality'"
              class="inline-flex items-center px-2 py-0.5 min-h-6 text-label-small rounded-md bg-n-alpha-2"
              :class="getQualityRatingTextColor(item.value)"
            >
              {{ item.value }}
            </span>
            <span
              v-else-if="item.type === 'status'"
              class="inline-flex items-center px-2 py-0.5 min-h-6 text-label-small rounded-md bg-n-alpha-2"
              :class="getStatusTextColor(item.value)"
            >
              {{ formatStatusDisplay(item.value) }}
            </span>
            <span
              v-else-if="item.type === 'mode'"
              class="inline-flex items-center px-2 py-0.5 min-h-6 text-label-small rounded-md bg-n-alpha-2"
              :class="getModeStatusTextColor(item.value)"
            >
              {{ formatModeDisplay(item.value) }}
            </span>
            <span
              v-else-if="item.type === 'tier'"
              class="text-label text-n-slate-12"
            >
              {{ formatTierDisplay(item.value) }}
            </span>
            <span v-else class="text-label text-n-slate-12">{{
              item.value
            }}</span>
          </div>
        </div>

        <!-- Webhook configuration card -->
        <div
          v-if="showWebhookSection"
          class="flex flex-col gap-2 p-4 rounded-lg border border-n-weak bg-n-solid-1"
        >
          <div class="flex gap-2 items-center">
            <span class="text-body-main font-medium text-n-slate-11">
              {{ t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.TITLE') }}
            </span>
            <Icon
              v-tooltip.top="t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.DESCRIPTION')"
              icon="i-lucide-info"
              class="flex-shrink-0 w-4 h-4 cursor-help text-n-slate-9"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <span
              v-if="webhookConfigured && !webhookUrlMismatch"
              class="inline-flex items-center gap-1.5 px-2 py-0.5 min-h-6 text-label-small rounded-md bg-n-alpha-2 text-n-teal-11"
            >
              <Icon icon="i-lucide-check-circle" class="w-3.5 h-3.5" />
              {{ t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.CONFIGURED_SUCCESS') }}
            </span>
            <span
              v-else
              class="inline-flex items-center gap-1.5 px-2 py-0.5 min-h-6 text-label-small rounded-md bg-n-alpha-2 text-n-amber-11"
            >
              <Icon icon="i-lucide-alert-triangle" class="w-3.5 h-3.5" />
              {{
                webhookUrlMismatch
                  ? t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.URL_MISMATCH')
                  : t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.ACTION_REQUIRED')
              }}
            </span>
            <ButtonV4
              v-if="!webhookConfigured || webhookUrlMismatch"
              sm
              solid
              blue
              :loading="isRegisteringWebhook"
              :disabled="isRegisteringWebhook"
              class="flex-shrink-0"
              @click="handleRegisterWebhook"
            >
              {{ t('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.REGISTER_BUTTON') }}
            </ButtonV4>
          </div>
        </div>
      </div>

      <div v-else class="pt-8">
        <div
          class="flex justify-center items-center p-8 text-center text-n-slate-11"
        >
          <div>
            <Icon icon="i-lucide-activity" class="mb-2 w-8 h-8" />
            <p class="text-body-main text-n-slate-11">
              {{ t('INBOX_MGMT.ACCOUNT_HEALTH.NO_DATA') }}
            </p>
          </div>
        </div>
      </div>

      <div v-if="recoveryItems.length" class="pt-6 space-y-3">
        <h3 class="text-heading-4 text-n-slate-12">
          {{ t('INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.TITLE') }}
        </h3>
        <div class="grid grid-cols-1 gap-4 xs:grid-cols-2">
          <div
            v-for="item in recoveryItems"
            :key="item.key"
            data-testid="whatsapp-recovery-status"
            class="flex flex-col gap-2 p-4 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <span class="text-body-main font-medium text-n-slate-11">
              {{ item.label }}
            </span>
            <span
              class="inline-flex self-start px-2 py-0.5 min-h-6 text-label-small capitalize rounded-md bg-n-alpha-2"
              :class="recoveryToneClass(item.value)"
            >
              {{ formatRecoveryState(item.value) }}
            </span>
            <p v-if="item.detail" class="mb-0 text-body-small text-n-slate-10">
              {{ item.detail }}
            </p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
