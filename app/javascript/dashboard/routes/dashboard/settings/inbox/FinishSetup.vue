<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import QRCode from 'qrcode';
import { useAlert } from 'dashboard/composables';
import EmptyState from '../../../../components/widgets/EmptyState.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import DuplicateInboxBanner from './channels/instagram/DuplicateInboxBanner.vue';
import EmailInboxFinish from './channels/emailChannels/EmailInboxFinish.vue';
import { useInbox } from 'dashboard/composables/useInbox';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const WHATSAPP_WEB_QR_TTL_MS = 75 * 1000;
const WHATSAPP_WEB_AUTO_REFRESH_COOLDOWN_MS = 8 * 1000;
const WHATSAPP_WEB_AUTO_REFRESH_MAX_ATTEMPTS = 3;

const isRefreshingWhatsappWebQr = ref(false);
const hasShownWhatsappWebConnectedAlert = ref(false);
const hasSeenWhatsappWebProvisioningCode = ref(false);
const whatsappWebPollingInterval = ref(null);
const whatsappWebRedirectTimeout = ref(null);
const whatsappWebAutoRefreshAttempts = ref(0);
const whatsappWebLastAutoRefreshAt = ref(0);
const whatsappWebAutoRefreshReason = ref('');
const isDocumentVisible = ref(
  typeof document === 'undefined'
    ? true
    : document.visibilityState === 'visible'
);

const qrCodes = reactive({
  whatsapp: '',
  messenger: '',
  telegram: '',
});

const currentInboxId = computed(() => {
  return route.params.inbox_id || route.params.inboxId || '';
});

const currentInbox = computed(() =>
  store.getters['inboxes/getInbox'](currentInboxId.value)
);

// Use useInbox composable with the inbox ID
const {
  isAWhatsAppCloudChannel,
  isATwilioChannel,
  isASmsInbox,
  isALineChannel,
  isAnEmailChannel,
  isAWhatsAppChannel,
  isAWhatsAppWebChannel,
  isAFacebookInbox,
  isATelegramChannel,
  isATwilioWhatsAppChannel,
} = useInbox(currentInboxId.value);

const isWhatsappWebSetupFlow = computed(() => {
  return (
    isAWhatsAppWebChannel.value || route.query.channel_type === 'whatsapp_web'
  );
});

const whatsappWebState = computed(() => {
  return currentInbox.value.additional_attributes?.evolution || {};
});

const whatsappWebStatus = computed(() => {
  return whatsappWebState.value.status || 'creating';
});

const whatsappWebConnectionState = computed(() => {
  return whatsappWebState.value.connection_state || 'unknown';
});

const isWhatsappWebConnected = computed(() => {
  return whatsappWebStatus.value === 'connected';
});

const isWhatsappWebHistorySyncing = computed(() => {
  return Boolean(whatsappWebState.value.history_sync_in_progress);
});

const whatsappWebQrCode = computed(() => {
  return whatsappWebState.value.qrcode?.base64 || '';
});

const whatsappWebPairingCode = computed(() => {
  return (
    whatsappWebState.value.qrcode?.pairing_code ||
    whatsappWebState.value.qrcode?.pairingCode ||
    ''
  );
});

const formattedWhatsappWebPairingCode = computed(() => {
  const sanitizedCode = whatsappWebPairingCode.value.replace(/\W/g, '');
  if (!sanitizedCode) {
    return '';
  }

  if (sanitizedCode.length <= 4) {
    return sanitizedCode;
  }

  return `${sanitizedCode.slice(0, 4)}-${sanitizedCode.slice(4)}`;
});

const whatsappWebError = computed(() => {
  return whatsappWebState.value.last_error || '';
});

const whatsappWebQrGeneratedAt = computed(() => {
  return whatsappWebState.value.qr_generated_at || '';
});

const whatsappWebQrGeneratedAtMs = computed(() => {
  const timestamp = Date.parse(whatsappWebQrGeneratedAt.value);
  return Number.isNaN(timestamp) ? 0 : timestamp;
});

const whatsappWebQrFingerprint = computed(() => {
  return [
    whatsappWebQrGeneratedAt.value,
    whatsappWebQrCode.value.slice(0, 64),
    formattedWhatsappWebPairingCode.value,
  ].join(':');
});

const canAutoRefreshWhatsappWebQr = computed(() => {
  return (
    whatsappWebAutoRefreshAttempts.value <
    WHATSAPP_WEB_AUTO_REFRESH_MAX_ATTEMPTS
  );
});

const isWhatsappWebQrStale = computed(() => {
  if (!whatsappWebQrGeneratedAtMs.value || isWhatsappWebConnected.value) {
    return false;
  }

  return Date.now() - whatsappWebQrGeneratedAtMs.value >= WHATSAPP_WEB_QR_TTL_MS;
});

const isWhatsappWebRecoverableFailure = computed(() => {
  return ['failed', 'disconnected'].includes(whatsappWebStatus.value);
});

const shouldShowWhatsappWebRefresh = computed(() => {
  return (
    isAWhatsAppWebChannel.value &&
    currentInbox.value?.id &&
    whatsappWebStatus.value !== 'connected'
  );
});

const shouldShowWhatsappWebSuccessCard = computed(() => {
  return isWhatsappWebSetupFlow.value && isWhatsappWebConnected.value;
});

const shouldShowWhatsappWebLoader = computed(() => {
  return (
    isWhatsappWebSetupFlow.value &&
    (isRefreshingWhatsappWebQr.value ||
      !currentInbox.value?.id ||
      ((!whatsappWebQrCode.value && !formattedWhatsappWebPairingCode.value) &&
        ['creating', 'waiting_for_qr', 'disconnected'].includes(
          whatsappWebStatus.value
        )))
  );
});

const whatsappWebSuccessDescription = computed(() => {
  if (isWhatsappWebHistorySyncing.value) {
    return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HINT');
  }

  return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_REDIRECT');
});

const whatsappWebStatusMessage = computed(() => {
  if (!isWhatsappWebSetupFlow.value) {
    return '';
  }

  if (!currentInbox.value?.id) {
    return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTING');
  }

  switch (whatsappWebStatus.value) {
    case 'connected':
      return isWhatsappWebHistorySyncing.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HISTORY')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED');
    case 'failed':
      if (isRefreshingWhatsappWebQr.value) {
        return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.RECOVERING');
      }

      return whatsappWebError.value
        ? `${t('INBOX_MGMT.FINISH.WHATSAPP_WEB.FAILED')} ${whatsappWebError.value}`
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.FAILED');
    case 'qr_ready':
      if (isRefreshingWhatsappWebQr.value && whatsappWebAutoRefreshReason.value) {
        return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_EXPIRED_REFRESHING');
      }

      return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.SCAN_HINT');
    case 'disconnected':
      return isRefreshingWhatsappWebQr.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.RECOVERING')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTING');
    default:
      if (isRefreshingWhatsappWebQr.value && whatsappWebAutoRefreshReason.value) {
        return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_EXPIRED_REFRESHING');
      }

      return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTING');
  }
});

const hasDuplicateInstagramInbox = computed(() => {
  const instagramId = currentInbox.value.instagram_id;
  const facebookInbox =
    store.getters['inboxes/getFacebookInboxByInstagramId'](instagramId);

  return (
    currentInbox.value.channel_type === INBOX_TYPES.INSTAGRAM && facebookInbox
  );
});

const shouldShowWhatsAppWebhookDetails = computed(() => {
  return (
    isAWhatsAppCloudChannel.value &&
    currentInbox.value.provider_config?.source !== 'embedded_signup'
  );
});

const isWhatsAppEmbeddedSignup = computed(() => {
  return (
    isAWhatsAppCloudChannel.value &&
    currentInbox.value.provider_config?.source === 'embedded_signup'
  );
});

const finishTitle = computed(() => {
  if (isWhatsappWebSetupFlow.value) {
    return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.TITLE');
  }

  return t('INBOX_MGMT.FINISH.TITLE');
});

const message = computed(() => {
  if (isWhatsappWebSetupFlow.value) {
    return '';
  }

  if (isATwilioChannel.value) {
    return `${t('INBOX_MGMT.FINISH.MESSAGE')}. ${t(
      'INBOX_MGMT.ADD.TWILIO.API_CALLBACK.SUBTITLE'
    )}`;
  }

  if (isASmsInbox.value) {
    return `${t('INBOX_MGMT.FINISH.MESSAGE')}. ${t(
      'INBOX_MGMT.ADD.SMS.BANDWIDTH.API_CALLBACK.SUBTITLE'
    )}`;
  }

  if (isALineChannel.value) {
    return `${t('INBOX_MGMT.FINISH.MESSAGE')}. ${t(
      'INBOX_MGMT.ADD.LINE_CHANNEL.API_CALLBACK.SUBTITLE'
    )}`;
  }

  if (isAWhatsAppCloudChannel.value && shouldShowWhatsAppWebhookDetails.value) {
    return `${t('INBOX_MGMT.FINISH.MESSAGE')}. ${t(
      'INBOX_MGMT.ADD.WHATSAPP.API_CALLBACK.SUBTITLE'
    )}`;
  }

  if (currentInbox.value.web_widget_script) {
    return t('INBOX_MGMT.FINISH.WEBSITE_SUCCESS');
  }

  if (isWhatsAppEmbeddedSignup.value) {
    return `${t('INBOX_MGMT.FINISH.MESSAGE')}. ${t(
      'INBOX_MGMT.FINISH.WHATSAPP_QR_INSTRUCTION'
    )}`;
  }
  return t('INBOX_MGMT.FINISH.MESSAGE');
});

const shouldShowFinishActions = computed(() => {
  if (!isWhatsappWebSetupFlow.value) {
    return true;
  }

  return isWhatsappWebConnected.value;
});

async function generateQRCode(platform, identifier) {
  if (!identifier || !identifier.trim()) {
    // eslint-disable-next-line no-console
    console.warn(`Invalid identifier for ${platform} QR code`);
    return;
  }

  try {
    const platformUrls = {
      whatsapp: id => `https://wa.me/${id}`,
      messenger: id => `https://m.me/${id}`,
      telegram: id => `https://t.me/${id}`,
    };

    const url = platformUrls[platform](identifier);
    const qrDataUrl = await QRCode.toDataURL(url);
    qrCodes[platform] = qrDataUrl;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error(`Error generating ${platform} QR code:`, error);
    qrCodes[platform] = '';
  }
}

async function generateQRCodes() {
  if (!currentInbox.value) return;

  // WhatsApp (both Cloud and Twilio)
  if (currentInbox.value.phone_number && isAWhatsAppChannel.value) {
    // For Twilio WhatsApp, phone_number format is "whatsapp:+1234567890"
    // Extract just the phone number part for QR code generation
    const phoneNumber = currentInbox.value.phone_number.replace(
      'whatsapp:',
      ''
    );
    await generateQRCode('whatsapp', phoneNumber);
  }

  // Facebook Messenger
  if (currentInbox.value.page_id && isAFacebookInbox.value) {
    await generateQRCode('messenger', currentInbox.value.page_id);
  }

  // Telegram
  if (isATelegramChannel.value && currentInbox.value.bot_name) {
    await generateQRCode('telegram', currentInbox.value.bot_name);
  }
}

async function refreshWhatsappWebQr({ silent = false, autoReason = '' } = {}) {
  if (!isAWhatsAppWebChannel.value || !currentInbox.value?.id) {
    return;
  }

  try {
    if (autoReason) {
      whatsappWebAutoRefreshAttempts.value += 1;
      whatsappWebLastAutoRefreshAt.value = Date.now();
      whatsappWebAutoRefreshReason.value = autoReason;
    } else {
      whatsappWebAutoRefreshAttempts.value = 0;
      whatsappWebLastAutoRefreshAt.value = Date.now();
      whatsappWebAutoRefreshReason.value = '';
    }

    isRefreshingWhatsappWebQr.value = true;
    await store.dispatch('inboxes/refreshWhatsappWebQr', {
      inboxId: currentInbox.value.id,
      statusOnly: false,
    });
    if (!silent) {
      useAlert(t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REFRESH_SUCCESS'));
    }
  } catch (error) {
    if (!silent) {
      useAlert(
        error.message || t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REFRESH_ERROR')
      );
    }
  } finally {
    isRefreshingWhatsappWebQr.value = false;
  }
}

function stopWhatsappWebPolling() {
  if (whatsappWebPollingInterval.value) {
    window.clearInterval(whatsappWebPollingInterval.value);
    whatsappWebPollingInterval.value = null;
  }
}

function clearWhatsappWebRedirectTimeout() {
  if (whatsappWebRedirectTimeout.value) {
    window.clearTimeout(whatsappWebRedirectTimeout.value);
    whatsappWebRedirectTimeout.value = null;
  }
}

function shouldPollWhatsappWebStatus() {
  return (
    isWhatsappWebSetupFlow.value &&
    isDocumentVisible.value &&
    currentInbox.value?.id &&
    whatsappWebStatus.value !== 'connected' &&
    (whatsappWebStatus.value !== 'failed' || canAutoRefreshWhatsappWebQr.value)
  );
}

function syncWhatsappWebPolling() {
  stopWhatsappWebPolling();

  if (!shouldPollWhatsappWebStatus()) {
    return;
  }

  whatsappWebPollingInterval.value = window.setInterval(() => {
    maybeAutoRefreshWhatsappWebQr();
    if (isRefreshingWhatsappWebQr.value) {
      return;
    }

    store
      .dispatch('inboxes/refreshWhatsappWebQr', {
        inboxId: currentInbox.value.id,
        statusOnly: true,
      })
      .catch(() => {});
  }, 5000);
}

async function ensureInboxLoaded() {
  if (!currentInboxId.value || currentInbox.value?.id) {
    return;
  }

  try {
    await store.dispatch('inboxes/get');
  } catch (error) {
    // Ignore fetch failures here; the screen already handles missing data gracefully.
  }
}

function maybeAutoRefreshWhatsappWebQr() {
  if (
    !isAWhatsAppWebChannel.value ||
    !isWhatsappWebSetupFlow.value ||
    !currentInbox.value?.id ||
    !isDocumentVisible.value ||
    whatsappWebStatus.value === 'connected' ||
    isRefreshingWhatsappWebQr.value ||
    !canAutoRefreshWhatsappWebQr.value
  ) {
    return;
  }

  if (
    whatsappWebLastAutoRefreshAt.value &&
    Date.now() - whatsappWebLastAutoRefreshAt.value <
      WHATSAPP_WEB_AUTO_REFRESH_COOLDOWN_MS
  ) {
    return;
  }

  let autoReason = '';

  if (
    !whatsappWebQrCode.value &&
    !formattedWhatsappWebPairingCode.value &&
    !hasSeenWhatsappWebProvisioningCode.value &&
    whatsappWebConnectionState.value !== 'connecting' &&
    ['creating', 'waiting_for_qr'].includes(whatsappWebStatus.value)
  ) {
    autoReason = 'initial';
  } else if (isWhatsappWebQrStale.value) {
    autoReason = 'stale';
  } else if (isWhatsappWebRecoverableFailure.value) {
    autoReason = 'recovery';
  }

  if (!autoReason) {
    return;
  }

  refreshWhatsappWebQr({ silent: true, autoReason }).catch(() => {});
}

function maybeCompleteWhatsappWebSetup() {
  clearWhatsappWebRedirectTimeout();

  if (
    !isWhatsappWebSetupFlow.value ||
    !isWhatsappWebConnected.value ||
    !currentInboxId.value
  ) {
    return;
  }

  if (!hasShownWhatsappWebConnectedAlert.value) {
    useAlert(
      t(
        isWhatsappWebHistorySyncing.value
          ? 'INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HISTORY'
          : 'INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SUCCESS'
      )
    );
    hasShownWhatsappWebConnectedAlert.value = true;
  }

  whatsappWebRedirectTimeout.value = window.setTimeout(() => {
    router.replace({
      name: 'settings_inbox_show',
      params: {
        accountId: route.params.accountId,
        inboxId: currentInboxId.value,
      },
    });
  }, 1500);
}

function handleVisibilityChange() {
  if (typeof document === 'undefined') {
    return;
  }

  isDocumentVisible.value = document.visibilityState === 'visible';
  if (isDocumentVisible.value) {
    maybeAutoRefreshWhatsappWebQr();
  }
  syncWhatsappWebPolling();
}

// Watch for currentInbox changes and regenerate QR codes when available
watch(
  currentInbox,
  newInbox => {
    if (newInbox) {
      generateQRCodes();
      maybeAutoRefreshWhatsappWebQr();
    }
  },
  { immediate: true }
);

watch(currentInboxId, () => {
  ensureInboxLoaded();
});

watch(
  [
    currentInboxId,
    isWhatsappWebSetupFlow,
    whatsappWebStatus,
    whatsappWebQrCode,
    whatsappWebQrGeneratedAt,
    canAutoRefreshWhatsappWebQr,
  ],
  () => {
    maybeAutoRefreshWhatsappWebQr();
    syncWhatsappWebPolling();
  }
);

watch(whatsappWebQrFingerprint, (nextFingerprint, previousFingerprint) => {
  if (
    nextFingerprint &&
    nextFingerprint !== previousFingerprint &&
    whatsappWebQrGeneratedAt.value
  ) {
    whatsappWebAutoRefreshReason.value = '';
  }
});

watch(
  [whatsappWebQrCode, formattedWhatsappWebPairingCode],
  ([nextQrCode, nextPairingCode]) => {
    if (nextQrCode || nextPairingCode) {
      hasSeenWhatsappWebProvisioningCode.value = true;
    }
  },
  { immediate: true }
);

watch(
  [isWhatsappWebSetupFlow, isWhatsappWebConnected, currentInboxId],
  () => {
    maybeCompleteWhatsappWebSetup();
  },
  { immediate: true }
);

onMounted(() => {
  ensureInboxLoaded();
  generateQRCodes();
  maybeAutoRefreshWhatsappWebQr();
  maybeCompleteWhatsappWebSetup();
  syncWhatsappWebPolling();
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', handleVisibilityChange);
  }
});

onBeforeUnmount(() => {
  stopWhatsappWebPolling();
  clearWhatsappWebRedirectTimeout();
  if (typeof document !== 'undefined') {
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  }
});
</script>

<template>
  <div class="overflow-auto col-span-6 p-6 w-full h-full">
    <DuplicateInboxBanner
      v-if="hasDuplicateInstagramInbox"
      :content="$t('INBOX_MGMT.ADD.INSTAGRAM.NEW_INBOX_SUGGESTION')"
    />
    <EmptyState
      :title="finishTitle"
      :message="isAnEmailChannel && !currentInbox.provider ? '' : message"
      :button-text="$t('INBOX_MGMT.FINISH.BUTTON_TEXT')"
    >
      <div class="w-full text-center">
        <div class="my-4 mx-auto max-w-[70%]">
          <woot-code
            v-if="currentInbox.web_widget_script"
            :script="currentInbox.web_widget_script"
          />
        </div>
        <div class="w-[50%] max-w-[50%] ml-[25%]">
          <woot-code
            v-if="isATwilioWhatsAppChannel"
            lang="html"
            :script="currentInbox.callback_webhook_url"
          />
        </div>
        <div
          v-if="shouldShowWhatsAppWebhookDetails"
          class="w-[50%] max-w-[50%] ml-[25%]"
        >
          <p class="mt-8 font-medium text-n-slate-11">
            {{ $t('INBOX_MGMT.ADD.WHATSAPP.API_CALLBACK.WEBHOOK_URL') }}
          </p>
          <woot-code lang="html" :script="currentInbox.callback_webhook_url" />
          <p class="mt-8 font-medium text-n-slate-11">
            {{
              $t(
                'INBOX_MGMT.ADD.WHATSAPP.API_CALLBACK.WEBHOOK_VERIFICATION_TOKEN'
              )
            }}
          </p>
          <woot-code
            lang="html"
            :script="currentInbox.provider_config.webhook_verify_token"
          />
        </div>
        <div class="w-[50%] max-w-[50%] ml-[25%]">
          <woot-code
            v-if="isALineChannel"
            lang="html"
            :script="currentInbox.callback_webhook_url"
          />
        </div>
        <div class="w-[50%] max-w-[50%] ml-[25%]">
          <woot-code
            v-if="isASmsInbox"
            lang="html"
            :script="currentInbox.callback_webhook_url"
          />
        </div>
        <EmailInboxFinish
          v-if="isAnEmailChannel && !currentInbox.provider"
          :inbox="currentInbox"
          :inbox-id="currentInboxId"
        />
        <div
          v-if="isAWhatsAppChannel && qrCodes.whatsapp"
          class="flex flex-col gap-3 items-center mt-8"
        >
          <p class="mt-2 text-sm text-n-slate-9">
            {{ $t('INBOX_MGMT.FINISH.WHATSAPP_QR_INSTRUCTION') }}
          </p>
          <div class="rounded-lg shadow outline-1 outline-n-strong outline">
            <img
              :src="qrCodes.whatsapp"
              :alt="$t('INBOX_MGMT.FINISH.WHATSAPP_QR_ALT')"
              class="rounded-lg size-48 dark:invert"
            />
          </div>
        </div>
        <div
          v-if="isWhatsappWebSetupFlow"
          class="flex flex-col gap-4 items-center mt-8"
        >
          <div
            class="flex size-14 items-center justify-center rounded-2xl bg-[#25D366]/10 text-[#25D366]"
          >
            <i class="i-ri-whatsapp-line text-[1.75rem]" />
          </div>
          <p
            v-if="whatsappWebStatusMessage"
            class="max-w-xl text-center text-sm leading-6 text-n-slate-10"
          >
            {{ whatsappWebStatusMessage }}
          </p>
          <div
            v-if="shouldShowWhatsappWebSuccessCard"
            class="flex w-full max-w-xl flex-col items-center gap-2 rounded-2xl border border-[#25D366]/30 bg-[#25D366]/5 px-6 py-5 text-center"
          >
            <div
              class="flex size-10 items-center justify-center rounded-full bg-[#25D366] text-white"
            >
              <i class="i-ri-check-line text-xl" />
            </div>
            <p class="text-sm font-semibold text-n-slate-12">
              {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SUCCESS') }}
            </p>
            <p class="text-sm leading-6 text-n-slate-10">
              {{ whatsappWebSuccessDescription }}
            </p>
            <p
              v-if="isWhatsappWebHistorySyncing"
              class="inline-flex items-center gap-2 text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
            >
              <Spinner :size="14" class="text-[#25D366]" />
              {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HISTORY') }}
            </p>
          </div>
          <div
            v-if="shouldShowWhatsappWebLoader"
            class="flex w-full max-w-xl flex-col items-center gap-3 rounded-2xl border border-dashed border-n-strong px-6 py-8"
          >
            <Spinner class="text-[#25D366]" :size="28" />
            <p class="text-sm font-medium text-n-slate-11">
              {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.LOADING_TITLE') }}
            </p>
          </div>
          <div
            v-if="whatsappWebQrCode && !isWhatsappWebConnected"
            class="rounded-lg shadow outline-1 outline-n-strong outline"
          >
            <img
              :src="whatsappWebQrCode"
              :alt="$t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_ALT')"
              class="rounded-lg size-48"
            />
          </div>
          <div
            v-if="
              formattedWhatsappWebPairingCode &&
              whatsappWebStatus !== 'connected'
            "
            class="rounded-2xl border border-[#25D366]/30 bg-[#25D366]/5 px-6 py-4 text-center"
          >
            <p
              class="mb-2 text-xs font-medium uppercase tracking-[0.12em] text-n-slate-10"
            >
              {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.PAIR_CODE_LABEL') }}
            </p>
            <p
              class="font-mono text-2xl font-semibold tracking-[0.22em] text-n-slate-12"
            >
              {{ formattedWhatsappWebPairingCode }}
            </p>
          </div>
          <NextButton
            v-if="shouldShowWhatsappWebRefresh"
            :is-loading="isRefreshingWhatsappWebQr"
            outline
            slate
            :label="$t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_NEW_QR')"
            @click="refreshWhatsappWebQr()"
          />
        </div>
        <div
          v-if="isAFacebookInbox && qrCodes.messenger"
          class="flex flex-col gap-3 items-center mt-8"
        >
          <p class="mt-2 text-sm text-n-slate-9">
            {{ $t('INBOX_MGMT.FINISH.MESSENGER_QR_INSTRUCTION') }}
          </p>
          <div class="rounded-lg shadow outline-1 outline-n-strong outline">
            <img
              :src="qrCodes.messenger"
              :alt="$t('INBOX_MGMT.FINISH.MESSENGER_QR_ALT')"
              class="rounded-lg size-48 dark:invert"
            />
          </div>
        </div>
        <div
          v-if="isATelegramChannel && qrCodes.telegram"
          class="flex flex-col gap-4 items-center mt-8"
        >
          <p class="mt-2 text-sm text-n-slate-9">
            {{ $t('INBOX_MGMT.FINISH.TELEGRAM_QR_INSTRUCTION') }}
          </p>

          <div class="rounded-lg shadow outline-1 outline-n-strong outline">
            <img
              :src="qrCodes.telegram"
              :alt="$t('INBOX_MGMT.FINISH.TELEGRAM_QR_ALT')"
              class="rounded-lg size-48 dark:invert"
            />
          </div>
        </div>
        <div
          v-if="shouldShowFinishActions"
          class="flex gap-2 justify-center mt-4"
        >
          <router-link
            :to="{
              name: 'settings_inbox_show',
              params: { inboxId: currentInboxId },
            }"
          >
            <NextButton
              outline
              slate
              :label="$t('INBOX_MGMT.FINISH.MORE_SETTINGS')"
            />
          </router-link>
          <router-link
            :to="{
              name: 'inbox_dashboard',
              params: { inbox_id: currentInboxId },
            }"
          >
            <NextButton
              solid
              teal
              :label="$t('INBOX_MGMT.FINISH.BUTTON_TEXT')"
            />
          </router-link>
        </div>
      </div>
    </EmptyState>
  </div>
</template>
