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
import { isInboxPendingDeletion } from 'dashboard/helper/whatsappWeb';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const WHATSAPP_WEB_QR_TTL_MS = 75 * 1000;
const WHATSAPP_WEB_AUTO_REFRESH_COOLDOWN_MS = 8 * 1000;
const WHATSAPP_WEB_AUTO_REFRESH_MAX_ATTEMPTS = 3;
const TELEGRAM_PERSONAL_REDIRECT_DELAY_MS = 1500;
const TELEGRAM_PERSONAL_POLL_INTERVAL_MS = 5000;

const isRefreshingWhatsappWebQr = ref(false);
const hasScheduledWhatsappWebCompletion = ref(false);
const hasSeenWhatsappWebProvisioningCode = ref(false);
const isDashboardDarkTheme = ref(
  typeof document === 'undefined'
    ? false
    : document.body.classList.contains('dark')
);
const whatsappWebThemeObserver = ref(null);
const whatsappWebPollingInterval = ref(null);
const whatsappWebRedirectTimeout = ref(null);
const whatsappWebAutoRefreshAttempts = ref(0);
const whatsappWebLastAutoRefreshAt = ref(0);
const whatsappWebAutoRefreshReason = ref('');
const whatsappWebThemedQrCode = ref('');
const isDocumentVisible = ref(
  typeof document === 'undefined'
    ? true
    : document.visibilityState === 'visible'
);
const telegramPersonalRedirectTimeout = ref(null);
const telegramPersonalPollingInterval = ref(null);
const telegramPersonalCode = ref('');
const telegramPersonalPassword = ref('');
const telegramPersonalImportFullHistory = ref(false);
const isRequestingTelegramPersonalCode = ref(false);
const isRequestingTelegramPersonalQr = ref(false);
const isVerifyingTelegramPersonalCode = ref(false);
const isVerifyingTelegramPersonalPassword = ref(false);
const isSchedulingTelegramPersonalFullHistory = ref(false);
const hasHandledTelegramPersonalSetupFullHistory = ref(false);
const telegramPersonalQrCode = ref('');

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
  isATelegramPersonalChannel,
  isATwilioWhatsAppChannel,
} = useInbox(currentInboxId.value);

const isWhatsappWebSetupFlow = computed(() => {
  return (
    isAWhatsAppWebChannel.value || route.query.channel_type === 'whatsapp_web'
  );
});

const isTelegramPersonalSetupFlow = computed(() => {
  return (
    isATelegramPersonalChannel.value ||
    route.query.channel_type === 'telegram_personal'
  );
});

const telegramPersonalRuntimeState = computed(() => {
  return currentInbox.value?.runtime_state || {};
});

const telegramPersonalAuthState = computed(() => {
  return telegramPersonalRuntimeState.value.auth_state || 'pending_auth';
});

const telegramPersonalLifecycleState = computed(() => {
  return (
    currentInbox.value?.lifecycle_state ||
    telegramPersonalRuntimeState.value.lifecycle_state ||
    'pending_auth'
  );
});

const telegramPersonalConnectionState = computed(() => {
  return (
    currentInbox.value?.connection_state ||
    telegramPersonalRuntimeState.value.connection_state ||
    'disconnected'
  );
});

const telegramPersonalLastError = computed(() => {
  return (
    currentInbox.value?.last_error ||
    telegramPersonalRuntimeState.value.last_error ||
    ''
  );
});

const isTelegramPersonalConnected = computed(() => {
  return (
    telegramPersonalLifecycleState.value === 'connected' ||
    telegramPersonalAuthState.value === 'authorized'
  );
});

const isTelegramPersonalPasswordRequired = computed(() => {
  return telegramPersonalLifecycleState.value === 'password_required';
});

const hasTelegramPersonalCodeStep = computed(() => {
  return ['code_sent', 'password_required', 'connected'].includes(
    telegramPersonalLifecycleState.value
  );
});

const shouldShowTelegramPersonalCodeRequest = computed(() => {
  return (
    !isTelegramPersonalConnected.value &&
    !isTelegramPersonalPasswordRequired.value &&
    !hasTelegramPersonalCodeStep.value
  );
});

const shouldShowTelegramPersonalCodeVerify = computed(() => {
  return (
    !isTelegramPersonalConnected.value &&
    !isTelegramPersonalPasswordRequired.value &&
    hasTelegramPersonalCodeStep.value
  );
});

const telegramPersonalQrUrl = computed(() => {
  return telegramPersonalRuntimeState.value.qr_login_url || '';
});

const telegramPersonalQrExpiresAt = computed(() => {
  return telegramPersonalRuntimeState.value.qr_login_expires_at || '';
});

const hasTelegramPersonalQrStep = computed(() => {
  return ['qr_ready', 'qr_expired'].includes(
    telegramPersonalLifecycleState.value
  );
});

const telegramPersonalRequestButtonLabel = computed(() => {
  return hasTelegramPersonalCodeStep.value
    ? t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_NEW_CODE')
    : t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE');
});

const telegramPersonalQrButtonLabel = computed(() => {
  return hasTelegramPersonalQrStep.value
    ? t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REFRESH_QR')
    : t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_QR');
});

const telegramPersonalStatusMessage = computed(() => {
  if (!isTelegramPersonalSetupFlow.value) {
    return '';
  }

  if (!currentInbox.value?.id) {
    return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.LOADING');
  }

  if (isRequestingTelegramPersonalCode.value) {
    return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUESTING_CODE');
  }

  if (isRequestingTelegramPersonalQr.value) {
    return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUESTING_QR');
  }

  if (isSchedulingTelegramPersonalFullHistory.value) {
    return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUESTING_FULL_HISTORY');
  }

  switch (telegramPersonalLifecycleState.value) {
    case 'connected':
      return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CONNECTED');
    case 'password_required':
      return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_REQUIRED');
    case 'code_sent':
      return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_SENT');
    case 'qr_ready':
      return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_READY');
    case 'qr_expired':
      return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_EXPIRED');
    case 'failed':
      return telegramPersonalLastError.value
        ? `${t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.FAILED')} ${telegramPersonalLastError.value}`
        : t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.FAILED');
    default:
      return t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.AUTH_METHOD_HINT');
  }
});

const whatsappWebState = computed(() => {
  return currentInbox.value?.additional_attributes?.evolution || {};
});

const whatsappWebStatus = computed(() => {
  return (
    currentInbox.value?.lifecycle_state ||
    whatsappWebState.value.status ||
    'creating'
  );
});

const whatsappWebConnectionState = computed(() => {
  return (
    currentInbox.value?.connection_state ||
    whatsappWebState.value.connection_state ||
    'unknown'
  );
});

const isWhatsappWebDeleting = computed(() => {
  return isInboxPendingDeletion(currentInbox.value);
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

const whatsappWebQrValue = computed(() => {
  return whatsappWebState.value.qrcode?.code || '';
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
    whatsappWebQrValue.value.slice(0, 64),
    formattedWhatsappWebPairingCode.value,
  ].join(':');
});

const whatsappWebDisplayQrCode = computed(() => {
  return whatsappWebThemedQrCode.value || whatsappWebQrCode.value || '';
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

  return (
    Date.now() - whatsappWebQrGeneratedAtMs.value >= WHATSAPP_WEB_QR_TTL_MS
  );
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
      (!whatsappWebDisplayQrCode.value &&
        !formattedWhatsappWebPairingCode.value &&
        ['creating', 'waiting_for_qr', 'reconnecting', 'disconnected'].includes(
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
      if (
        isRefreshingWhatsappWebQr.value &&
        whatsappWebAutoRefreshReason.value
      ) {
        return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_EXPIRED_REFRESHING');
      }

      return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.SCAN_HINT');
    case 'reconnecting':
      return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.RECONNECTING');
    case 'disconnected':
      return isRefreshingWhatsappWebQr.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.RECOVERING')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTING');
    default:
      if (
        isRefreshingWhatsappWebQr.value &&
        whatsappWebAutoRefreshReason.value
      ) {
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
  if (isWhatsappWebSetupFlow.value || isTelegramPersonalSetupFlow.value) {
    return '';
  }

  return t('INBOX_MGMT.FINISH.TITLE');
});

const message = computed(() => {
  if (isWhatsappWebSetupFlow.value || isTelegramPersonalSetupFlow.value) {
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
  if (isWhatsappWebSetupFlow.value) {
    return isWhatsappWebConnected.value;
  }

  if (isTelegramPersonalSetupFlow.value) {
    return isTelegramPersonalConnected.value;
  }

  if (!isWhatsappWebSetupFlow.value) {
    return true;
  }

  return false;
});

function clearTelegramPersonalRedirectTimeout() {
  if (telegramPersonalRedirectTimeout.value) {
    window.clearTimeout(telegramPersonalRedirectTimeout.value);
    telegramPersonalRedirectTimeout.value = null;
  }
}

async function maybeScheduleTelegramPersonalSetupFullHistorySync({
  silent = true,
  markHandled = false,
} = {}) {
  if (!telegramPersonalImportFullHistory.value || !currentInbox.value?.id) {
    if (markHandled) {
      hasHandledTelegramPersonalSetupFullHistory.value = true;
    }
    return;
  }

  if (
    hasHandledTelegramPersonalSetupFullHistory.value ||
    isSchedulingTelegramPersonalFullHistory.value
  ) {
    return;
  }

  hasHandledTelegramPersonalSetupFullHistory.value = true;

  try {
    isSchedulingTelegramPersonalFullHistory.value = true;
    await store.dispatch('inboxes/historySyncTelegramPersonal', {
      inboxId: currentInbox.value.id,
      payload: {
        force: true,
        reset_cursor: true,
        include_contacts: false,
      },
    });

    if (!silent) {
      useAlert(
        t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC_SUCCESS')
      );
    }
  } catch (error) {
    if (!silent) {
      useAlert(
        error.message ||
          t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC_ERROR')
      );
    }
  } finally {
    isSchedulingTelegramPersonalFullHistory.value = false;
  }
}

function stopTelegramPersonalPolling() {
  if (telegramPersonalPollingInterval.value) {
    window.clearInterval(telegramPersonalPollingInterval.value);
    telegramPersonalPollingInterval.value = null;
  }
}

async function fetchTelegramPersonalDiagnostics() {
  if (!currentInbox.value?.id) {
    return;
  }

  try {
    await store.dispatch(
      'inboxes/getTelegramPersonalDiagnostics',
      currentInbox.value.id
    );
  } catch (error) {
    // Diagnostics stay best-effort during setup.
  }
}

function shouldPollTelegramPersonalStatus() {
  return (
    isTelegramPersonalSetupFlow.value &&
    isDocumentVisible.value &&
    currentInbox.value?.id &&
    !isTelegramPersonalConnected.value
  );
}

function syncTelegramPersonalPolling() {
  stopTelegramPersonalPolling();

  if (!shouldPollTelegramPersonalStatus()) {
    return;
  }

  telegramPersonalPollingInterval.value = window.setInterval(() => {
    fetchTelegramPersonalDiagnostics();
  }, TELEGRAM_PERSONAL_POLL_INTERVAL_MS);
}

async function renderTelegramPersonalQrCode() {
  if (!telegramPersonalQrUrl.value) {
    telegramPersonalQrCode.value = '';
    return;
  }

  try {
    telegramPersonalQrCode.value = await QRCode.toDataURL(
      telegramPersonalQrUrl.value,
      {
        margin: 0,
        width: 512,
      }
    );
  } catch (error) {
    telegramPersonalQrCode.value = '';
  }
}

async function requestTelegramPersonalCode({ silent = false } = {}) {
  if (!currentInbox.value?.id) {
    return;
  }

  if (isRequestingTelegramPersonalCode.value) {
    return;
  }

  try {
    isRequestingTelegramPersonalCode.value = true;
    await store.dispatch(
      'inboxes/requestTelegramPersonalCode',
      currentInbox.value.id
    );
    telegramPersonalCode.value = '';
    telegramPersonalPassword.value = '';
    if (!silent) {
      useAlert(t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE_SUCCESS'));
    }
  } catch (error) {
    if (!silent) {
      useAlert(
        error.message ||
          t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE_ERROR')
      );
    }
  } finally {
    isRequestingTelegramPersonalCode.value = false;
  }
}

async function requestTelegramPersonalQr({ silent = false } = {}) {
  if (!currentInbox.value?.id) {
    return;
  }

  if (isRequestingTelegramPersonalQr.value) {
    return;
  }

  try {
    isRequestingTelegramPersonalQr.value = true;
    await store.dispatch(
      'inboxes/requestTelegramPersonalQr',
      currentInbox.value.id
    );
    telegramPersonalCode.value = '';
    telegramPersonalPassword.value = '';
    if (!silent) {
      useAlert(t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_QR_SUCCESS'));
    }
  } catch (error) {
    if (!silent) {
      useAlert(
        error.message ||
          t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_QR_ERROR')
      );
    }
  } finally {
    isRequestingTelegramPersonalQr.value = false;
  }
}

async function verifyTelegramPersonalCode() {
  if (!telegramPersonalCode.value.trim()) {
    useAlert(t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_REQUIRED'));
    return;
  }

  if (isVerifyingTelegramPersonalCode.value) {
    return;
  }

  try {
    isVerifyingTelegramPersonalCode.value = true;
    await store.dispatch('inboxes/verifyTelegramPersonalCode', {
      inboxId: currentInbox.value.id,
      code: telegramPersonalCode.value.trim(),
    });
    telegramPersonalCode.value = '';
    await maybeScheduleTelegramPersonalSetupFullHistorySync({
      silent: true,
      markHandled: true,
    });
  } catch (error) {
    useAlert(
      error.message ||
        t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.VERIFY_CODE_ERROR')
    );
  } finally {
    isVerifyingTelegramPersonalCode.value = false;
  }
}

async function verifyTelegramPersonalPassword() {
  if (!telegramPersonalPassword.value.trim()) {
    useAlert(t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_REQUIRED_ERROR'));
    return;
  }

  if (isVerifyingTelegramPersonalPassword.value) {
    return;
  }

  try {
    isVerifyingTelegramPersonalPassword.value = true;
    await store.dispatch('inboxes/verifyTelegramPersonalPassword', {
      inboxId: currentInbox.value.id,
      password: telegramPersonalPassword.value.trim(),
    });
    telegramPersonalPassword.value = '';
    await maybeScheduleTelegramPersonalSetupFullHistorySync({
      silent: true,
      markHandled: true,
    });
  } catch (error) {
    useAlert(
      error.message ||
        t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.VERIFY_PASSWORD_ERROR')
    );
  } finally {
    isVerifyingTelegramPersonalPassword.value = false;
  }
}

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

  if (isWhatsappWebDeleting.value) {
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

function syncDashboardThemeState() {
  if (typeof document === 'undefined') {
    return;
  }

  isDashboardDarkTheme.value = document.body.classList.contains('dark');
}

async function renderWhatsappWebQrForTheme() {
  if (!whatsappWebQrValue.value) {
    whatsappWebThemedQrCode.value = '';
    return;
  }

  try {
    whatsappWebThemedQrCode.value = await QRCode.toDataURL(
      whatsappWebQrValue.value,
      {
        margin: 0,
        width: 672,
        color: {
          dark: isDashboardDarkTheme.value ? '#FFFFFF' : '#000000',
          light: '#0000',
        },
      }
    );
  } catch (error) {
    whatsappWebThemedQrCode.value = '';
  }
}

function shouldPollWhatsappWebStatus() {
  return (
    isWhatsappWebSetupFlow.value &&
    isDocumentVisible.value &&
    currentInbox.value?.id &&
    !isWhatsappWebDeleting.value &&
    whatsappWebStatus.value !== 'connected' &&
    (whatsappWebStatus.value !== 'failed' || canAutoRefreshWhatsappWebQr.value)
  );
}

function maybeAutoRefreshWhatsappWebQr() {
  if (
    !isAWhatsAppWebChannel.value ||
    !isWhatsappWebSetupFlow.value ||
    !currentInbox.value?.id ||
    isWhatsappWebDeleting.value ||
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
        includeQrCode: true,
      })
      .catch(() => {});
  }, 5000);
}

async function ensureInboxLoaded() {
  if (!currentInboxId.value || currentInbox.value?.id) {
    return Boolean(currentInboxId.value && currentInbox.value?.id);
  }

  try {
    await store.dispatch('inboxes/get');
  } catch (error) {
    return null;
  }

  return Boolean(store.getters['inboxes/getInbox'](currentInboxId.value)?.id);
}

async function redirectToInboxListIfMissing() {
  if (!currentInboxId.value) {
    return;
  }

  const inboxExists = await ensureInboxLoaded();
  if (inboxExists !== false) {
    return;
  }

  stopWhatsappWebPolling();
  stopTelegramPersonalPolling();
  clearWhatsappWebRedirectTimeout();
  clearTelegramPersonalRedirectTimeout();

  router.replace({
    name: 'settings_inbox_list',
    params: {
      accountId: route.params.accountId,
    },
  });
}

function maybeCompleteWhatsappWebSetup() {
  clearWhatsappWebRedirectTimeout();

  if (
    !isWhatsappWebSetupFlow.value ||
    !isWhatsappWebConnected.value ||
    !currentInboxId.value
  ) {
    hasScheduledWhatsappWebCompletion.value = false;
    return;
  }

  if (hasScheduledWhatsappWebCompletion.value) {
    return;
  }

  hasScheduledWhatsappWebCompletion.value = true;

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

function maybeCompleteTelegramPersonalSetup() {
  clearTelegramPersonalRedirectTimeout();

  if (
    !isTelegramPersonalSetupFlow.value ||
    !isTelegramPersonalConnected.value ||
    !currentInboxId.value
  ) {
    return;
  }

  if (
    telegramPersonalImportFullHistory.value &&
    !hasHandledTelegramPersonalSetupFullHistory.value
  ) {
    maybeScheduleTelegramPersonalSetupFullHistorySync({
      silent: true,
      markHandled: true,
    }).finally(() => {
      maybeCompleteTelegramPersonalSetup();
    });
    return;
  }

  telegramPersonalRedirectTimeout.value = window.setTimeout(() => {
    router.replace({
      name: 'settings_inbox_show',
      params: {
        accountId: route.params.accountId,
        inboxId: currentInboxId.value,
      },
    });
  }, TELEGRAM_PERSONAL_REDIRECT_DELAY_MS);
}

function handleVisibilityChange() {
  if (typeof document === 'undefined') {
    return;
  }

  isDocumentVisible.value = document.visibilityState === 'visible';
  if (isDocumentVisible.value) {
    maybeAutoRefreshWhatsappWebQr();
    fetchTelegramPersonalDiagnostics();
  }
  syncWhatsappWebPolling();
  syncTelegramPersonalPolling();
}

// Watch for currentInbox changes and regenerate QR codes when available
watch(
  currentInbox,
  async newInbox => {
    if (currentInboxId.value && !newInbox?.id) {
      await redirectToInboxListIfMissing();
      return;
    }

    if (newInbox) {
      generateQRCodes();
      maybeAutoRefreshWhatsappWebQr();
      renderTelegramPersonalQrCode();
    }
  },
  { immediate: true }
);

watch(currentInboxId, async () => {
  await redirectToInboxListIfMissing();
  telegramPersonalCode.value = '';
  telegramPersonalPassword.value = '';
  telegramPersonalQrCode.value = '';
  telegramPersonalImportFullHistory.value = false;
  hasHandledTelegramPersonalSetupFullHistory.value = false;
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
  [whatsappWebQrValue, isDashboardDarkTheme],
  () => {
    renderWhatsappWebQrForTheme();
  },
  { immediate: true }
);

watch(telegramPersonalQrUrl, () => {
  renderTelegramPersonalQrCode();
});

watch(
  [isWhatsappWebSetupFlow, isWhatsappWebConnected, currentInboxId],
  () => {
    maybeCompleteWhatsappWebSetup();
  },
  { immediate: true }
);

watch(
  [
    isTelegramPersonalSetupFlow,
    telegramPersonalLifecycleState,
    isTelegramPersonalConnected,
    currentInboxId,
  ],
  () => {
    maybeCompleteTelegramPersonalSetup();
    syncTelegramPersonalPolling();
  },
  { immediate: true }
);

onMounted(() => {
  ensureInboxLoaded();
  generateQRCodes();
  renderTelegramPersonalQrCode();
  syncDashboardThemeState();
  maybeAutoRefreshWhatsappWebQr();
  maybeCompleteWhatsappWebSetup();
  maybeCompleteTelegramPersonalSetup();
  syncWhatsappWebPolling();
  syncTelegramPersonalPolling();
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', handleVisibilityChange);
    if (document.body) {
      whatsappWebThemeObserver.value = new MutationObserver(() => {
        syncDashboardThemeState();
      });
      whatsappWebThemeObserver.value.observe(document.body, {
        attributes: true,
        attributeFilter: ['class'],
      });
    }
  }
});

onBeforeUnmount(() => {
  stopWhatsappWebPolling();
  stopTelegramPersonalPolling();
  clearWhatsappWebRedirectTimeout();
  clearTelegramPersonalRedirectTimeout();
  whatsappWebThemeObserver.value?.disconnect();
  whatsappWebThemeObserver.value = null;
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
        <div v-if="isWhatsappWebSetupFlow" class="mt-8 w-full">
          <div
            class="mx-auto grid w-full max-w-4xl gap-6 rounded-[28px] border border-n-weak bg-n-solid-1 p-6 text-left lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start lg:p-8"
          >
            <div class="flex min-h-full flex-col gap-5">
              <div class="flex items-center gap-4">
                <div
                  class="flex size-14 shrink-0 items-center justify-center rounded-2xl bg-[#25D366]/10 text-[#25D366]"
                >
                  <i class="i-ri-whatsapp-line text-[1.75rem]" />
                </div>
                <div class="min-w-0">
                  <p class="text-lg font-semibold text-n-slate-12">
                    {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.TITLE') }}
                  </p>
                  <p class="mt-1 text-sm leading-6 text-n-slate-10">
                    {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.DESCRIPTION') }}
                  </p>
                </div>
              </div>

              <p
                v-if="whatsappWebStatusMessage"
                class="text-sm leading-6 text-n-slate-10"
              >
                {{ whatsappWebStatusMessage }}
              </p>

              <div
                v-if="shouldShowWhatsappWebSuccessCard"
                class="flex w-full flex-col items-start gap-2 rounded-2xl border border-[#25D366]/30 bg-[#25D366]/5 px-6 py-5"
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
                  {{
                    $t(
                      'INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HISTORY'
                    )
                  }}
                </p>
              </div>

              <div
                v-if="
                  formattedWhatsappWebPairingCode &&
                  whatsappWebStatus !== 'connected'
                "
                class="rounded-2xl border border-[#25D366]/30 bg-[#25D366]/5 px-6 py-4"
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

              <p class="mt-auto text-sm leading-6 text-n-slate-10">
                {{
                  whatsappWebStatus === 'connected'
                    ? $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_REDIRECT')
                    : $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_DESCRIPTION')
                }}
              </p>
            </div>

            <div class="flex flex-col items-center gap-4">
              <div
                v-if="shouldShowWhatsappWebLoader"
                class="flex min-h-[22rem] w-full max-w-[21rem] flex-col items-center justify-center gap-3 rounded-2xl border border-dashed border-n-strong px-6 py-8"
              >
                <Spinner class="text-[#25D366]" :size="28" />
                <p class="text-sm font-medium text-n-slate-11">
                  {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.LOADING_TITLE') }}
                </p>
              </div>
              <div
                v-else-if="whatsappWebDisplayQrCode && !isWhatsappWebConnected"
                class="flex w-full items-center justify-center"
              >
                <img
                  :src="whatsappWebDisplayQrCode"
                  :alt="$t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_ALT')"
                  class="h-auto w-full max-w-[21rem]"
                />
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
          </div>
        </div>
        <div v-if="isTelegramPersonalSetupFlow" class="mt-8 w-full">
          <div class="mx-auto flex w-full max-w-5xl flex-col gap-6 text-left">
            <div
              class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,20rem)] lg:items-start"
            >
              <div class="flex min-h-full flex-col gap-5">
                <div class="flex items-center gap-4">
                  <div
                    class="flex size-14 shrink-0 items-center justify-center rounded-2xl bg-[#229ED9]/10 text-[#229ED9]"
                  >
                    <i class="i-ri-telegram-line text-[1.75rem]" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-lg font-semibold text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.TITLE') }}
                    </p>
                    <p class="mt-1 text-sm leading-6 text-n-slate-10">
                      {{
                        $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.DESCRIPTION')
                      }}
                    </p>
                  </div>
                </div>

                <p
                  v-if="telegramPersonalStatusMessage"
                  class="text-sm leading-6 text-n-slate-10"
                >
                  {{ telegramPersonalStatusMessage }}
                </p>

                <div
                  v-if="isTelegramPersonalConnected"
                  class="flex w-full flex-col items-start gap-2 rounded-2xl border border-[#229ED9]/30 bg-[#229ED9]/5 px-6 py-5"
                >
                  <div
                    class="flex size-10 items-center justify-center rounded-full bg-[#229ED9] text-white"
                  >
                    <i class="i-ri-check-line text-xl" />
                  </div>
                  <p class="text-sm font-semibold text-n-slate-12">
                    {{
                      $t(
                        'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CONNECTED_SUCCESS'
                      )
                    }}
                  </p>
                  <p class="text-sm leading-6 text-n-slate-10">
                    {{
                      $t(
                        'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CONNECTED_REDIRECT'
                      )
                    }}
                  </p>
                </div>
              </div>

              <div
                v-if="currentInbox?.id"
                class="rounded-2xl border border-n-weak bg-n-surface-1 p-4"
              >
                <div class="space-y-2 text-sm text-n-slate-11">
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{
                        $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PHONE_NUMBER')
                      }}
                    </span>
                    {{ currentInbox?.phone_number || '—' }}
                  </p>
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.STATUS') }}
                    </span>
                    {{ telegramPersonalLifecycleState }}
                  </p>
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CONNECTION') }}
                    </span>
                    {{ telegramPersonalConnectionState }}
                  </p>
                  <p v-if="telegramPersonalLastError" class="text-rose-600">
                    <span class="font-medium">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.LAST_ERROR') }}
                    </span>
                    {{ telegramPersonalLastError }}
                  </p>
                </div>
                <label
                  v-if="!isTelegramPersonalConnected"
                  class="mt-4 flex items-center gap-3 border-t border-n-weak pt-4"
                >
                  <input
                    v-model="telegramPersonalImportFullHistory"
                    type="checkbox"
                    class="size-4 rounded border-n-strong text-n-brand focus:ring-n-brand"
                  />
                  <span class="text-sm font-medium text-n-slate-12">
                    {{
                      $t(
                        'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC_LABEL'
                      )
                    }}
                  </span>
                </label>
              </div>
            </div>

            <div class="flex w-full flex-col gap-4">
              <div
                v-if="!currentInbox?.id"
                class="flex min-h-[22rem] w-full flex-col items-center justify-center gap-3 rounded-2xl border border-dashed border-n-strong px-6 py-8"
              >
                <Spinner class="text-[#229ED9]" :size="28" />
                <p class="text-sm font-medium text-n-slate-11">
                  {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.LOADING') }}
                </p>
              </div>

              <form
                v-else-if="isTelegramPersonalPasswordRequired"
                class="max-w-[21rem] space-y-3 rounded-2xl border border-n-weak bg-n-surface-1 p-5"
                @submit.prevent="verifyTelegramPersonalPassword"
              >
                <p class="text-sm font-medium text-n-slate-12">
                  {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_LABEL') }}
                </p>
                <input
                  v-model="telegramPersonalPassword"
                  class="!mb-0 w-full rounded-lg border-0 bg-n-solid-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                  type="password"
                  autocomplete="current-password"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_PLACEHOLDER'
                    )
                  "
                />
                <p class="text-sm leading-6 text-n-slate-10">
                  {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_HINT') }}
                </p>
                <NextButton
                  class="w-full"
                  solid
                  blue
                  type="submit"
                  :is-loading="isVerifyingTelegramPersonalPassword"
                  :label="
                    $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.VERIFY_PASSWORD')
                  "
                />
              </form>

              <template v-else-if="!isTelegramPersonalConnected">
                <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                  <div
                    v-if="shouldShowTelegramPersonalCodeRequest"
                    class="space-y-3 rounded-2xl border border-n-weak bg-n-surface-1 p-5"
                  >
                    <p class="text-sm font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_LOGIN') }}
                    </p>
                    <p class="text-sm leading-6 text-n-slate-10">
                      {{
                        $t(
                          'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE_HINT'
                        )
                      }}
                    </p>
                    <NextButton
                      class="w-full"
                      type="button"
                      outline
                      slate
                      :is-loading="isRequestingTelegramPersonalCode"
                      :label="telegramPersonalRequestButtonLabel"
                      @click.prevent="requestTelegramPersonalCode()"
                    />
                  </div>

                  <form
                    v-else-if="shouldShowTelegramPersonalCodeVerify"
                    class="space-y-3 rounded-2xl border border-n-weak bg-n-surface-1 p-5"
                    @submit.prevent="verifyTelegramPersonalCode"
                  >
                    <p class="text-sm font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_LOGIN') }}
                    </p>
                    <input
                      v-model="telegramPersonalCode"
                      class="!mb-0 w-full rounded-lg border-0 bg-n-solid-1 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                      type="text"
                      inputmode="numeric"
                      autocomplete="one-time-code"
                      :placeholder="
                        $t(
                          'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_PLACEHOLDER'
                        )
                      "
                    />
                    <p class="text-sm leading-6 text-n-slate-10">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_HINT') }}
                    </p>
                    <NextButton
                      class="w-full"
                      solid
                      blue
                      type="submit"
                      :is-loading="isVerifyingTelegramPersonalCode"
                      :label="
                        $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.VERIFY_CODE')
                      "
                    />
                  </form>

                  <div
                    class="rounded-2xl border border-n-weak bg-n-surface-1 p-5"
                  >
                    <p class="text-sm font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_LOGIN') }}
                    </p>
                    <p class="mt-2 text-sm leading-6 text-n-slate-10">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_HINT') }}
                    </p>

                    <div
                      v-if="telegramPersonalQrCode"
                      class="mt-4 flex items-center justify-center rounded-2xl bg-white p-4"
                    >
                      <img
                        :src="telegramPersonalQrCode"
                        :alt="
                          $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_IMAGE_ALT')
                        "
                        class="h-auto w-full max-w-[15rem]"
                      />
                    </div>
                    <div
                      v-else
                      class="mt-4 rounded-2xl border border-dashed border-n-strong px-4 py-8 text-center text-sm text-n-slate-10"
                    >
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_EMPTY') }}
                    </div>

                    <p
                      v-if="telegramPersonalQrExpiresAt"
                      class="mt-3 text-xs text-n-slate-10"
                    >
                      {{
                        $t(
                          'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_EXPIRES_AT',
                          {
                            value: telegramPersonalQrExpiresAt,
                          }
                        )
                      }}
                    </p>

                    <NextButton
                      class="mt-4 w-full"
                      type="button"
                      outline
                      slate
                      :is-loading="isRequestingTelegramPersonalQr"
                      :label="telegramPersonalQrButtonLabel"
                      @click="requestTelegramPersonalQr()"
                    />
                  </div>
                </div>
              </template>
            </div>
          </div>
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
