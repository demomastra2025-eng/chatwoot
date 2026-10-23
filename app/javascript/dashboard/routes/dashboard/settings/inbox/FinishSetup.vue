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
import {
  getWhatsappWebConnectionState,
  getWhatsappWebLifecycleState,
  isInboxPendingDeletion,
  isWhatsappWebConnected as hasOpenWhatsappWebSession,
  isWhatsappWebWorkingRecently,
} from 'dashboard/helper/whatsappWeb';
import { getInboxFlowRouteName } from './helpers/inboxFlowRoutes';
import {
  clearOneTimeWebhookVerifyToken,
  getOneTimeWebhookVerifyToken,
} from 'shared/helpers/whatsappCloudCredentials';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const TELEGRAM_PERSONAL_REDIRECT_DELAY_MS = 1500;
const TELEGRAM_PERSONAL_POLL_INTERVAL_MS = 5000;
const WEIXIN_REDIRECT_DELAY_MS = 1500;
const WEIXIN_POLL_INTERVAL_MS = 5000;

const isRefreshingWhatsappWebQr = ref(false);
const hasScheduledWhatsappWebCompletion = ref(false);
const isDashboardDarkTheme = ref(
  typeof document === 'undefined'
    ? false
    : document.body.classList.contains('dark')
);
const whatsappWebThemeObserver = ref(null);
const whatsappWebPollingInterval = ref(null);
const isWhatsappWebPollingEnabled = ref(false);
const whatsappWebRedirectTimeout = ref(null);
const whatsappWebThemedQrCode = ref('');
const isRequestingWhatsappWebCode = ref(false);
const isRequestingWhatsappWebQr = ref(false);
const isSyncingWhatsappWebStatus = ref(false);
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
const weixinRedirectTimeout = ref(null);
const weixinPollingInterval = ref(null);
const isRequestingWeixinQr = ref(false);
const weixinQrCode = ref('');

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
  isAWeixinChannel,
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

const isWeixinSetupFlow = computed(() => {
  return isAWeixinChannel.value || route.query.channel_type === 'weixin';
});

const weixinRuntimeState = computed(() => {
  return currentInbox.value?.runtime_state || {};
});

const weixinLifecycleState = computed(() => {
  return (
    currentInbox.value?.lifecycle_state ||
    weixinRuntimeState.value.lifecycle_state ||
    'pending_auth'
  );
});

const weixinConnectionState = computed(() => {
  return (
    currentInbox.value?.connection_state ||
    weixinRuntimeState.value.connection_state ||
    'disconnected'
  );
});

const weixinLastError = computed(() => {
  return (
    currentInbox.value?.last_error || weixinRuntimeState.value.last_error || ''
  );
});

const isWeixinConnected = computed(() => {
  return (
    weixinLifecycleState.value === 'connected' ||
    weixinConnectionState.value === 'connected' ||
    weixinRuntimeState.value.connected === true ||
    weixinRuntimeState.value.authorized === true
  );
});

const weixinQrUrl = computed(() => {
  return weixinRuntimeState.value.qr_login_url || '';
});

const weixinQrExpiresAt = computed(() => {
  return weixinRuntimeState.value.qr_login_expires_at || '';
});

const hasWeixinQrStep = computed(() => {
  return (
    ['qr_ready', 'qr_scanned', 'qr_expired'].includes(
      weixinLifecycleState.value
    ) || Boolean(weixinQrUrl.value)
  );
});

const weixinQrButtonLabel = computed(() => {
  return hasWeixinQrStep.value
    ? t('INBOX_MGMT.FINISH.WEIXIN.REFRESH_QR')
    : t('INBOX_MGMT.FINISH.WEIXIN.REQUEST_QR');
});

const weixinStatusMessage = computed(() => {
  if (!isWeixinSetupFlow.value) {
    return '';
  }

  if (!currentInbox.value?.id) {
    return t('INBOX_MGMT.FINISH.WEIXIN.LOADING');
  }

  if (isRequestingWeixinQr.value) {
    return t('INBOX_MGMT.FINISH.WEIXIN.REQUESTING_QR');
  }

  if (isWeixinConnected.value) {
    return t('INBOX_MGMT.FINISH.WEIXIN.CONNECTED');
  }

  switch (weixinLifecycleState.value) {
    case 'qr_ready':
    case 'qr_scanned':
      return t('INBOX_MGMT.FINISH.WEIXIN.QR_READY');
    case 'qr_expired':
      return t('INBOX_MGMT.FINISH.WEIXIN.QR_EXPIRED');
    case 'failed':
      return weixinLastError.value
        ? `${t('INBOX_MGMT.FINISH.WEIXIN.FAILED')} ${weixinLastError.value}`
        : t('INBOX_MGMT.FINISH.WEIXIN.FAILED');
    default:
      return t('INBOX_MGMT.FINISH.WEIXIN.REQUEST_QR_HINT');
  }
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

const isTelegramPersonalConnected = computed(() => {
  return (
    telegramPersonalLifecycleState.value === 'connected' ||
    telegramPersonalAuthState.value === 'authorized'
  );
});

const telegramPersonalLastError = computed(() => {
  if (isTelegramPersonalConnected.value) {
    return '';
  }

  return (
    currentInbox.value?.last_error ||
    telegramPersonalRuntimeState.value.last_error ||
    ''
  );
});

function humanizeSetupState(value) {
  if (!value) {
    return '—';
  }

  const normalizedKey = String(value)
    .trim()
    .replace(/[\s-]+/g, '_')
    .toUpperCase();
  const stateMap = {
    OPEN: 'CONNECTED',
    CLOSE: 'DISCONNECTED',
    WAITING_FOR_QR: 'QR_READY',
    CREATING: 'CONNECTING',
    RECONNECTING: 'CONNECTING',
  };
  const lookupKey = stateMap[normalizedKey] || normalizedKey;
  const translationKey = `INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.STATE_LABELS.${lookupKey}`;
  const translatedValue = t(translationKey);

  if (translatedValue !== translationKey) {
    return translatedValue;
  }

  const normalizedValue = String(value).replace(/_/g, ' ');
  return normalizedValue.charAt(0).toUpperCase() + normalizedValue.slice(1);
}

function setupStateBadgeClass(value) {
  const normalizedValue = String(value || '').toLowerCase();

  if (
    ['connected', 'authorized', 'open', 'completed'].includes(normalizedValue)
  ) {
    return 'bg-n-teal-9/10 text-n-teal-11';
  }

  if (
    [
      'pending_auth',
      'code_sent',
      'qr_ready',
      'waiting_for_qr',
      'creating',
      'password_required',
      'connecting',
      'reconnecting',
      'scheduled',
      'running',
    ].includes(normalizedValue)
  ) {
    return 'bg-n-amber-9/10 text-n-amber-11';
  }

  if (
    ['failed', 'disconnected', 'close', 'qr_expired', 'flood_wait'].includes(
      normalizedValue
    )
  ) {
    return 'bg-n-ruby-9/10 text-n-ruby-11';
  }

  return 'bg-n-alpha-2 text-n-slate-11';
}

function formatSetupDate(value) {
  if (!value) return '';
  const parsedValue = new Date(value);
  if (Number.isNaN(parsedValue.getTime())) return value;
  try {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
      hour12: false,
    }).format(parsedValue);
  } catch {
    return value;
  }
}

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
  return getWhatsappWebLifecycleState(currentInbox.value) || 'creating';
});

const whatsappWebConnectionState = computed(() => {
  return getWhatsappWebConnectionState(currentInbox.value);
});

const isWhatsappWebConnected = computed(() => {
  return (
    hasOpenWhatsappWebSession(currentInbox.value) ||
    (whatsappWebStatus.value === 'connected' &&
      whatsappWebConnectionState.value === 'open')
  );
});

const isWhatsappWebDeleting = computed(() => {
  return isInboxPendingDeletion(currentInbox.value);
});

const isWhatsappWebLifecycleBusy = computed(() => {
  return (
    isRefreshingWhatsappWebQr.value ||
    isRequestingWhatsappWebCode.value ||
    isRequestingWhatsappWebQr.value ||
    isSyncingWhatsappWebStatus.value
  );
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

const hasWhatsappWebPairingCode = computed(() => {
  return Boolean(whatsappWebPairingCode.value);
});

const hasWhatsappWebQrImage = computed(() => {
  return Boolean(whatsappWebQrCode.value);
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

const whatsappWebDisplayQrCode = computed(() => {
  return whatsappWebThemedQrCode.value || whatsappWebQrCode.value || '';
});

const shouldShowWhatsappWebSuccessCard = computed(() => {
  return isWhatsappWebSetupFlow.value && isWhatsappWebConnected.value;
});

const hasWhatsappWebAuthArtifacts = computed(() => {
  return Boolean(
    whatsappWebQrCode.value ||
      whatsappWebQrValue.value ||
      formattedWhatsappWebPairingCode.value
  );
});

const whatsappWebRequestQrButtonLabel = computed(() => {
  return hasWhatsappWebQrImage.value
    ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_NEW_QR')
    : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_QR');
});

const whatsappWebRequestCodeButtonLabel = computed(() => {
  return hasWhatsappWebPairingCode.value
    ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_NEW_CODE')
    : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_CODE');
});

const shouldShowWhatsappWebQrLoader = computed(() => {
  return (
    isWhatsappWebSetupFlow.value &&
    (isRefreshingWhatsappWebQr.value ||
      isRequestingWhatsappWebQr.value ||
      !currentInbox.value?.id)
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

  if (isRequestingWhatsappWebCode.value) {
    return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUESTING_CODE');
  }

  if (isRefreshingWhatsappWebQr.value) {
    return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUESTING_QR');
  }

  if (isRequestingWhatsappWebQr.value) {
    return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUESTING_QR');
  }

  switch (whatsappWebStatus.value) {
    case 'connected':
      return isWhatsappWebHistorySyncing.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HISTORY')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED');
    case 'failed':
      return whatsappWebError.value
        ? `${t('INBOX_MGMT.FINISH.WHATSAPP_WEB.FAILED')} ${whatsappWebError.value}`
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.FAILED');
    case 'qr_ready':
      return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.SCAN_HINT');
    case 'reconnecting':
      return t('INBOX_MGMT.FINISH.WHATSAPP_WEB.RECONNECTING');
    case 'disconnected':
      return hasWhatsappWebAuthArtifacts.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTING')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_QR_HINT');
    case 'creating':
    case 'waiting_for_qr':
      return hasWhatsappWebAuthArtifacts.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.SCAN_HINT')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_QR_HINT');
    default:
      return hasWhatsappWebAuthArtifacts.value
        ? t('INBOX_MGMT.FINISH.WHATSAPP_WEB.SCAN_HINT')
        : t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTING');
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

const whatsappWebhookVerifyToken = computed(() => {
  return (
    currentInbox.value?.provider_config?.webhook_verify_token ||
    getOneTimeWebhookVerifyToken(currentInboxId.value)
  );
});

const isWhatsAppEmbeddedSignup = computed(() => {
  return (
    isAWhatsAppCloudChannel.value &&
    currentInbox.value.provider_config?.source === 'embedded_signup'
  );
});

const finishTitle = computed(() => {
  if (
    isWhatsappWebSetupFlow.value ||
    isTelegramPersonalSetupFlow.value ||
    isWeixinSetupFlow.value
  ) {
    return '';
  }

  return t('INBOX_MGMT.FINISH.TITLE');
});

const message = computed(() => {
  if (
    isWhatsappWebSetupFlow.value ||
    isTelegramPersonalSetupFlow.value ||
    isWeixinSetupFlow.value
  ) {
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

  if (isWeixinSetupFlow.value) {
    return isWeixinConnected.value;
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

function clearWeixinRedirectTimeout() {
  if (weixinRedirectTimeout.value) {
    window.clearTimeout(weixinRedirectTimeout.value);
    weixinRedirectTimeout.value = null;
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
        include_contacts: true,
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

function stopWeixinPolling() {
  if (weixinPollingInterval.value) {
    window.clearInterval(weixinPollingInterval.value);
    weixinPollingInterval.value = null;
  }
}

async function fetchTelegramPersonalDiagnostics() {
  if (!isTelegramPersonalSetupFlow.value || !currentInbox.value?.id) {
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

async function fetchWeixinDiagnostics() {
  if (!isWeixinSetupFlow.value || !currentInbox.value?.id) {
    return;
  }

  try {
    await store.dispatch('inboxes/getWeixinDiagnostics', currentInbox.value.id);
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

function shouldPollWeixinStatus() {
  return (
    isWeixinSetupFlow.value &&
    isDocumentVisible.value &&
    currentInbox.value?.id &&
    !isWeixinConnected.value
  );
}

function syncWeixinPolling() {
  stopWeixinPolling();

  if (!shouldPollWeixinStatus()) {
    return;
  }

  weixinPollingInterval.value = window.setInterval(() => {
    fetchWeixinDiagnostics();
  }, WEIXIN_POLL_INTERVAL_MS);
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

async function renderWeixinQrCode() {
  if (!weixinQrUrl.value) {
    weixinQrCode.value = '';
    return;
  }

  try {
    weixinQrCode.value = await QRCode.toDataURL(weixinQrUrl.value, {
      margin: 0,
      width: 512,
    });
  } catch (error) {
    weixinQrCode.value = '';
  }
}

async function requestWeixinQr({ silent = false } = {}) {
  if (!currentInbox.value?.id || isRequestingWeixinQr.value) {
    return;
  }

  try {
    isRequestingWeixinQr.value = true;
    await store.dispatch('inboxes/requestWeixinQr', currentInbox.value.id);
    if (!silent) {
      useAlert(t('INBOX_MGMT.FINISH.WEIXIN.REQUEST_QR_SUCCESS'));
    }
  } catch (error) {
    if (!silent) {
      useAlert(error.message || t('INBOX_MGMT.FINISH.WEIXIN.REQUEST_QR_ERROR'));
    }
  } finally {
    isRequestingWeixinQr.value = false;
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

async function refreshWhatsappWebQr({
  silent = false,
  artifactType = 'both',
} = {}) {
  if (!isAWhatsAppWebChannel.value || !currentInbox.value?.id) {
    return;
  }

  if (isWhatsappWebDeleting.value || isWhatsappWebLifecycleBusy.value) {
    return;
  }

  // A QR or pairing code replaces the current login, so a working one is only reset after an explicit confirmation.
  const isConfirmedReset = isWhatsappWebWorkingRecently(currentInbox.value);
  if (
    isConfirmedReset &&
    !window.confirm(t('INBOX_MGMT.EDIT.WHATSAPP_WEB.RESET_CONFIRM'))
  ) {
    return;
  }

  const isRequestingCode = artifactType === 'code';
  const isRequestingQr = artifactType === 'qr';

  if (isRequestingCode && isRequestingWhatsappWebCode.value) {
    return;
  }

  if (isRequestingQr && isRequestingWhatsappWebQr.value) {
    return;
  }

  if (isRequestingCode) {
    isRequestingWhatsappWebCode.value = true;
  } else if (isRequestingQr) {
    isRequestingWhatsappWebQr.value = true;
  } else {
    isRefreshingWhatsappWebQr.value = true;
  }

  try {
    await store.dispatch('inboxes/refreshWhatsappWebQr', {
      inboxId: currentInbox.value.id,
      statusOnly: false,
      artifactType,
      force: isConfirmedReset,
    });
    if (!silent) {
      let successMessage = t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REFRESH_SUCCESS');

      if (isRequestingCode) {
        successMessage = t(
          'INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_CODE_SUCCESS'
        );
      } else if (isRequestingQr) {
        successMessage = t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REQUEST_QR_SUCCESS');
      }

      useAlert(successMessage);
    }
  } catch (error) {
    if (!silent) {
      useAlert(
        error.message || t('INBOX_MGMT.FINISH.WHATSAPP_WEB.REFRESH_ERROR')
      );
    }
  } finally {
    if (isRequestingCode) {
      isRequestingWhatsappWebCode.value = false;
    } else if (isRequestingQr) {
      isRequestingWhatsappWebQr.value = false;
    } else {
      isRefreshingWhatsappWebQr.value = false;
    }
  }
}

function stopWhatsappWebPolling() {
  isWhatsappWebPollingEnabled.value = false;
  if (whatsappWebPollingInterval.value) {
    window.clearTimeout(whatsappWebPollingInterval.value);
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
        width: 1008,
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
    !isWhatsappWebConnected.value
  );
}

async function fetchWhatsappWebStatus() {
  if (
    !isWhatsappWebSetupFlow.value ||
    !isDocumentVisible.value ||
    !currentInbox.value?.id ||
    isWhatsappWebDeleting.value ||
    isWhatsappWebConnected.value ||
    isWhatsappWebLifecycleBusy.value
  ) {
    return;
  }

  try {
    isSyncingWhatsappWebStatus.value = true;
    await store.dispatch('inboxes/refreshWhatsappWebQr', {
      inboxId: currentInbox.value.id,
      statusOnly: true,
      includeQrCode: ['waiting_for_qr', 'qr_ready'].includes(
        whatsappWebStatus.value
      ),
    });
  } catch (error) {
    // Status sync stays best-effort during setup.
  } finally {
    isSyncingWhatsappWebStatus.value = false;
  }
}

function syncWhatsappWebPolling() {
  stopWhatsappWebPolling();

  if (!shouldPollWhatsappWebStatus()) {
    return;
  }

  isWhatsappWebPollingEnabled.value = true;
  whatsappWebPollingInterval.value = window.setTimeout(async () => {
    whatsappWebPollingInterval.value = null;
    await fetchWhatsappWebStatus();
    if (isWhatsappWebPollingEnabled.value) {
      syncWhatsappWebPolling();
    }
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
  stopWeixinPolling();
  clearWhatsappWebRedirectTimeout();
  clearTelegramPersonalRedirectTimeout();
  clearWeixinRedirectTimeout();

  router.replace({
    name: getInboxFlowRouteName(route, 'list'),
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
      name: getInboxFlowRouteName(route, 'show'),
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
      name: getInboxFlowRouteName(route, 'show'),
      params: {
        accountId: route.params.accountId,
        inboxId: currentInboxId.value,
      },
    });
  }, TELEGRAM_PERSONAL_REDIRECT_DELAY_MS);
}

function maybeCompleteWeixinSetup() {
  clearWeixinRedirectTimeout();

  if (
    !isWeixinSetupFlow.value ||
    !isWeixinConnected.value ||
    !currentInboxId.value
  ) {
    return;
  }

  weixinRedirectTimeout.value = window.setTimeout(() => {
    router.replace({
      name: getInboxFlowRouteName(route, 'show'),
      params: {
        accountId: route.params.accountId,
        inboxId: currentInboxId.value,
      },
    });
  }, WEIXIN_REDIRECT_DELAY_MS);
}

function handleVisibilityChange() {
  if (typeof document === 'undefined') {
    return;
  }

  isDocumentVisible.value = document.visibilityState === 'visible';
  if (isDocumentVisible.value) {
    fetchWhatsappWebStatus();
    fetchTelegramPersonalDiagnostics();
    fetchWeixinDiagnostics();
  }
  syncWhatsappWebPolling();
  syncTelegramPersonalPolling();
  syncWeixinPolling();
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
      renderTelegramPersonalQrCode();
      renderWeixinQrCode();
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
  weixinQrCode.value = '';
});

watch(
  [
    currentInboxId,
    isWhatsappWebSetupFlow,
    whatsappWebStatus,
    whatsappWebQrCode,
    whatsappWebQrGeneratedAt,
  ],
  () => {
    syncWhatsappWebPolling();
  }
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

watch(weixinQrUrl, () => {
  renderWeixinQrCode();
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

watch(
  [isWeixinSetupFlow, weixinLifecycleState, isWeixinConnected, currentInboxId],
  () => {
    maybeCompleteWeixinSetup();
    syncWeixinPolling();
  },
  { immediate: true }
);

onMounted(() => {
  ensureInboxLoaded().then(() => {
    fetchWhatsappWebStatus();
    fetchWeixinDiagnostics();
  });
  generateQRCodes();
  renderTelegramPersonalQrCode();
  renderWeixinQrCode();
  syncDashboardThemeState();
  maybeCompleteWhatsappWebSetup();
  maybeCompleteTelegramPersonalSetup();
  maybeCompleteWeixinSetup();
  syncWhatsappWebPolling();
  syncTelegramPersonalPolling();
  syncWeixinPolling();
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
  clearOneTimeWebhookVerifyToken(currentInboxId.value);
  stopWhatsappWebPolling();
  stopTelegramPersonalPolling();
  stopWeixinPolling();
  clearWhatsappWebRedirectTimeout();
  clearTelegramPersonalRedirectTimeout();
  clearWeixinRedirectTimeout();
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
          <woot-code lang="html" :script="whatsappWebhookVerifyToken" />
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
              class="rounded-lg size-72 dark:invert"
            />
          </div>
        </div>
        <div v-if="isWhatsappWebSetupFlow" class="mt-8 w-full">
          <div class="mx-auto flex w-full max-w-4xl flex-col gap-5 text-left">
            <div
              class="rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
            >
              <div
                class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between"
              >
                <div class="flex items-start gap-4">
                  <div
                    class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-n-teal-3 text-n-teal-11"
                  >
                    <i class="i-ri-whatsapp-line text-2xl" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-base font-semibold text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.TITLE') }}
                    </p>
                    <p class="mt-1 text-sm leading-relaxed text-n-slate-11">
                      {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.DESCRIPTION') }}
                    </p>
                  </div>
                </div>

                <div class="flex flex-wrap items-center gap-2 shrink-0">
                  <span
                    v-if="currentInbox?.phone_number || whatsappWebState.number"
                    class="inline-flex items-center gap-1.5 rounded-full bg-n-alpha-2 px-3 py-1 font-mono text-xs font-medium text-n-slate-12"
                  >
                    {{ currentInbox?.phone_number || whatsappWebState.number }}
                  </span>
                  <span
                    class="inline-flex items-center rounded-full px-3 py-1 text-xs font-medium"
                    :class="setupStateBadgeClass(whatsappWebStatus)"
                  >
                    {{ humanizeSetupState(whatsappWebStatus) }}
                  </span>
                </div>
              </div>

              <p
                v-if="whatsappWebStatusMessage"
                class="mt-4 border-t border-n-weak pt-3 text-sm leading-relaxed text-n-slate-11"
              >
                {{ whatsappWebStatusMessage }}
              </p>
            </div>

            <div
              v-if="shouldShowWhatsappWebSuccessCard"
              class="flex w-full flex-col items-start gap-2 rounded-2xl bg-n-teal-3 px-6 py-5 outline outline-1 -outline-offset-1 outline-n-teal-6"
            >
              <div
                class="flex size-10 items-center justify-center rounded-full bg-n-teal-9 text-white"
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
                <Spinner :size="14" class="text-n-teal-10" />
                {{
                  $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.CONNECTED_SYNCING_HISTORY')
                }}
              </p>
            </div>

            <div
              v-if="!isWhatsappWebConnected"
              class="grid grid-cols-1 gap-5 md:grid-cols-2 items-stretch"
            >
              <div
                class="flex flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
              >
                <div>
                  <p
                    class="text-xs font-semibold uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_CODE_LABEL') }}
                  </p>
                  <p class="mt-1.5 text-sm leading-relaxed text-n-slate-11">
                    {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_DESCRIPTION') }}
                  </p>

                  <div
                    v-if="
                      whatsappWebDisplayQrCode &&
                      !isWhatsappWebConnected &&
                      !shouldShowWhatsappWebQrLoader
                    "
                    class="mt-4 flex min-h-[16rem] w-full items-center justify-center rounded-xl border border-n-weak bg-white p-4"
                  >
                    <img
                      :src="whatsappWebDisplayQrCode"
                      :alt="$t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_ALT')"
                      class="block aspect-square h-auto w-full max-w-[15rem] object-contain"
                    />
                  </div>
                  <div
                    v-else-if="shouldShowWhatsappWebQrLoader"
                    class="mt-4 flex min-h-[16rem] w-full flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-n-weak bg-n-alpha-black2 px-6 py-8"
                  >
                    <Spinner class="text-n-teal-10" :size="28" />
                    <p class="text-sm font-medium text-n-slate-11">
                      {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.LOADING_TITLE') }}
                    </p>
                  </div>
                  <div
                    v-else
                    class="mt-4 flex min-h-[16rem] flex-col items-center justify-center rounded-xl border border-dashed border-n-weak bg-n-alpha-black2 px-4 py-6 text-center text-sm text-n-slate-10"
                  >
                    {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.QR_EMPTY') }}
                  </div>
                </div>

                <NextButton
                  class="mt-4 w-full"
                  type="button"
                  outline
                  slate
                  icon="i-lucide-qr-code"
                  :is-loading="isRequestingWhatsappWebQr"
                  :disabled="isWhatsappWebLifecycleBusy"
                  :label="whatsappWebRequestQrButtonLabel"
                  @click="refreshWhatsappWebQr({ artifactType: 'qr' })"
                />
              </div>

              <div
                class="flex flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
              >
                <div>
                  <p
                    class="text-xs font-semibold uppercase tracking-[0.08em] text-n-slate-10"
                  >
                    {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.PAIR_CODE_LABEL') }}
                  </p>
                  <p class="mt-1.5 text-sm leading-relaxed text-n-slate-11">
                    {{
                      $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.PAIR_CODE_DESCRIPTION')
                    }}
                  </p>

                  <div
                    class="mt-4 flex min-h-[16rem] flex-col items-center justify-center rounded-xl border border-dashed border-n-weak bg-n-alpha-black2 px-6 py-8 text-center"
                  >
                    <p
                      v-if="formattedWhatsappWebPairingCode"
                      class="font-mono text-2xl font-bold tracking-[0.22em] text-n-teal-11"
                    >
                      {{ formattedWhatsappWebPairingCode }}
                    </p>
                    <p v-else class="text-sm text-n-slate-10">
                      {{ $t('INBOX_MGMT.FINISH.WHATSAPP_WEB.PAIR_CODE_EMPTY') }}
                    </p>
                  </div>
                </div>

                <NextButton
                  class="mt-4 w-full"
                  type="button"
                  outline
                  slate
                  :is-loading="isRequestingWhatsappWebCode"
                  :disabled="isWhatsappWebLifecycleBusy"
                  :label="whatsappWebRequestCodeButtonLabel"
                  icon="i-lucide-key-round"
                  @click="refreshWhatsappWebQr({ artifactType: 'code' })"
                />
              </div>
            </div>
          </div>
        </div>
        <div v-if="isWeixinSetupFlow" class="mt-8 w-full">
          <div class="mx-auto flex w-full max-w-5xl flex-col gap-6 text-left">
            <div
              class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,20rem)] lg:items-start"
            >
              <div class="flex min-h-full flex-col gap-5">
                <div class="flex items-center gap-4">
                  <div
                    class="flex size-14 shrink-0 items-center justify-center rounded-xl bg-n-teal-3 text-n-teal-11"
                  >
                    <i class="i-ri-wechat-line text-[1.75rem]" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-lg font-semibold text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.TITLE') }}
                    </p>
                    <p class="mt-1 text-sm leading-6 text-n-slate-10">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.DESCRIPTION') }}
                    </p>
                  </div>
                </div>

                <p
                  v-if="weixinStatusMessage"
                  class="text-sm leading-6 text-n-slate-10"
                >
                  {{ weixinStatusMessage }}
                </p>

                <div
                  v-if="isWeixinConnected"
                  class="flex w-full flex-col items-start gap-2 rounded-xl bg-n-teal-3 px-6 py-5 outline outline-1 -outline-offset-1 outline-n-teal-6"
                >
                  <div
                    class="flex size-10 items-center justify-center rounded-full bg-n-teal-9 text-white"
                  >
                    <i class="i-ri-check-line text-xl" />
                  </div>
                  <p class="text-sm font-semibold text-n-slate-12">
                    {{ $t('INBOX_MGMT.FINISH.WEIXIN.CONNECTED_SUCCESS') }}
                  </p>
                  <p class="text-sm leading-6 text-n-slate-10">
                    {{ $t('INBOX_MGMT.FINISH.WEIXIN.CONNECTED_REDIRECT') }}
                  </p>
                </div>
              </div>

              <div
                v-if="currentInbox?.id"
                class="rounded-xl p-4 outline outline-1 -outline-offset-1 outline-n-weak"
              >
                <div class="space-y-2 text-sm text-n-slate-11">
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.DISPLAY_NAME') }}
                    </span>
                    {{ currentInbox?.display_name || '—' }}
                  </p>
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.PROVIDER_ACCOUNT_ID') }}
                    </span>
                    {{ currentInbox?.provider_account_id || '—' }}
                  </p>
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.STATUS') }}
                    </span>
                    {{ weixinLifecycleState }}
                  </p>
                  <p>
                    <span class="font-medium text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.CONNECTION') }}
                    </span>
                    {{ weixinConnectionState }}
                  </p>
                  <p v-if="weixinLastError" class="text-n-ruby-11">
                    <span class="font-medium">
                      {{ $t('INBOX_MGMT.FINISH.WEIXIN.LAST_ERROR') }}
                    </span>
                    {{ weixinLastError }}
                  </p>
                </div>
              </div>
            </div>

            <div class="flex w-full flex-col gap-4">
              <div
                v-if="!currentInbox?.id"
                class="flex min-h-[22rem] w-full flex-col items-center justify-center gap-3 px-6 py-8"
              >
                <Spinner class="text-n-teal-10" :size="28" />
                <p class="text-sm font-medium text-n-slate-11">
                  {{ $t('INBOX_MGMT.FINISH.WEIXIN.LOADING') }}
                </p>
              </div>

              <div
                v-else-if="!isWeixinConnected"
                class="max-w-[28rem] rounded-xl p-5 outline outline-1 -outline-offset-1 outline-n-weak"
              >
                <p class="text-sm font-medium text-n-slate-12">
                  {{ $t('INBOX_MGMT.FINISH.WEIXIN.QR_LOGIN') }}
                </p>
                <p class="mt-2 text-sm leading-6 text-n-slate-10">
                  {{ $t('INBOX_MGMT.FINISH.WEIXIN.QR_HINT') }}
                </p>

                <div
                  v-if="weixinQrCode"
                  class="mt-4 flex items-center justify-center rounded-lg bg-white p-4"
                >
                  <img
                    :src="weixinQrCode"
                    :alt="$t('INBOX_MGMT.FINISH.WEIXIN.QR_IMAGE_ALT')"
                    class="h-auto w-full max-w-[15rem]"
                  />
                </div>
                <div
                  v-else
                  class="mt-4 px-4 py-8 text-center text-sm text-n-slate-10"
                >
                  {{ $t('INBOX_MGMT.FINISH.WEIXIN.QR_EMPTY') }}
                </div>

                <p
                  v-if="weixinQrExpiresAt"
                  class="mt-3 text-xs text-n-slate-10"
                >
                  {{
                    $t('INBOX_MGMT.FINISH.WEIXIN.QR_EXPIRES_AT', {
                      value: weixinQrExpiresAt,
                    })
                  }}
                </p>

                <NextButton
                  class="mt-4 w-full"
                  type="button"
                  outline
                  slate
                  icon="i-lucide-qr-code"
                  :is-loading="isRequestingWeixinQr"
                  :label="weixinQrButtonLabel"
                  @click="requestWeixinQr()"
                />
              </div>
            </div>
          </div>
        </div>
        <div v-if="isTelegramPersonalSetupFlow" class="mt-8 w-full">
          <div class="mx-auto flex w-full max-w-4xl flex-col gap-5 text-left">
            <div
              class="rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
            >
              <div
                class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between"
              >
                <div class="flex items-start gap-4">
                  <div
                    class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-n-blue-3 text-n-blue-11"
                  >
                    <i class="i-ri-telegram-line text-2xl" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-base font-semibold text-n-slate-12">
                      {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.TITLE') }}
                    </p>
                    <p class="mt-1 text-sm leading-relaxed text-n-slate-11">
                      {{
                        $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.DESCRIPTION')
                      }}
                    </p>
                  </div>
                </div>

                <div
                  v-if="currentInbox?.id"
                  class="flex flex-wrap items-center gap-2 shrink-0"
                >
                  <span
                    class="inline-flex items-center rounded-full bg-n-alpha-2 px-3 py-1 font-mono text-xs font-medium text-n-slate-12"
                  >
                    {{ currentInbox?.phone_number || '—' }}
                  </span>
                  <span
                    class="inline-flex items-center rounded-full px-3 py-1 text-xs font-medium"
                    :class="
                      setupStateBadgeClass(telegramPersonalLifecycleState)
                    "
                  >
                    {{ humanizeSetupState(telegramPersonalLifecycleState) }}
                  </span>
                </div>
              </div>

              <div
                v-if="
                  telegramPersonalStatusMessage ||
                  !isTelegramPersonalConnected ||
                  telegramPersonalLastError
                "
                class="mt-4 flex flex-col gap-3 border-t border-n-weak pt-3"
              >
                <div
                  class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <p
                    v-if="telegramPersonalStatusMessage"
                    class="text-sm leading-relaxed text-n-slate-11"
                  >
                    {{ telegramPersonalStatusMessage }}
                  </p>
                  <label
                    v-if="!isTelegramPersonalConnected"
                    class="inline-flex items-center gap-2.5 cursor-pointer select-none shrink-0"
                  >
                    <input
                      v-model="telegramPersonalImportFullHistory"
                      type="checkbox"
                      class="size-4 rounded border-n-strong text-n-brand focus:ring-n-brand"
                    />
                    <span class="text-xs font-medium text-n-slate-12">
                      {{
                        $t(
                          'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.FULL_HISTORY_SYNC_LABEL'
                        )
                      }}
                    </span>
                  </label>
                </div>

                <div
                  v-if="telegramPersonalLastError"
                  class="rounded-xl border border-n-ruby-6/40 bg-n-ruby-3/50 px-3.5 py-2.5 text-xs text-n-ruby-11"
                >
                  <span class="font-semibold">
                    {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.LAST_ERROR') }}
                  </span>
                  {{ telegramPersonalLastError }}
                </div>
              </div>
            </div>

            <div
              v-if="isTelegramPersonalConnected"
              class="flex w-full flex-col items-start gap-2 rounded-2xl bg-n-blue-3 px-6 py-5 outline outline-1 -outline-offset-1 outline-n-blue-6"
            >
              <div
                class="flex size-10 items-center justify-center rounded-full bg-n-blue-9 text-white"
              >
                <i class="i-ri-check-line text-xl" />
              </div>
              <p class="text-sm font-semibold text-n-slate-12">
                {{
                  $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CONNECTED_SUCCESS')
                }}
              </p>
              <p class="text-sm leading-6 text-n-slate-10">
                {{
                  $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CONNECTED_REDIRECT')
                }}
              </p>
            </div>

            <div class="flex w-full flex-col gap-4">
              <div
                v-if="!currentInbox?.id"
                class="flex min-h-[18rem] w-full flex-col items-center justify-center gap-3 rounded-2xl border border-n-weak bg-n-solid-1 px-6 py-8"
              >
                <Spinner class="text-n-blue-10" :size="28" />
                <p class="text-sm font-medium text-n-slate-11">
                  {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.LOADING') }}
                </p>
              </div>

              <form
                v-else-if="isTelegramPersonalPasswordRequired"
                class="mx-auto w-full max-w-lg space-y-4 rounded-2xl border border-n-weak bg-n-solid-1 p-6 shadow-sm"
                @submit.prevent="verifyTelegramPersonalPassword"
              >
                <div>
                  <p class="text-sm font-semibold text-n-slate-12">
                    {{
                      $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_LABEL')
                    }}
                  </p>
                  <p class="mt-1 text-sm leading-relaxed text-n-slate-11">
                    {{
                      $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_HINT')
                    }}
                  </p>
                </div>
                <input
                  v-model="telegramPersonalPassword"
                  class="!mb-0 w-full rounded-xl border-0 bg-n-alpha-black2 px-3.5 py-2.5 text-sm text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                  type="password"
                  autocomplete="current-password"
                  :placeholder="
                    $t(
                      'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.PASSWORD_PLACEHOLDER'
                    )
                  "
                />
                <div class="flex flex-col gap-2 sm:flex-row">
                  <NextButton
                    class="flex-1"
                    solid
                    blue
                    type="submit"
                    :is-loading="isVerifyingTelegramPersonalPassword"
                    :label="
                      $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.VERIFY_PASSWORD')
                    "
                  />
                  <NextButton
                    type="button"
                    outline
                    slate
                    :is-loading="isRequestingTelegramPersonalQr"
                    :label="telegramPersonalQrButtonLabel"
                    @click="requestTelegramPersonalQr()"
                  />
                </div>
              </form>

              <template v-else-if="!isTelegramPersonalConnected">
                <div
                  class="grid grid-cols-1 gap-5 md:grid-cols-2 items-stretch"
                >
                  <div
                    class="flex flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
                  >
                    <div>
                      <p class="text-sm font-semibold text-n-slate-12">
                        {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_LOGIN') }}
                      </p>
                      <p class="mt-1.5 text-sm leading-relaxed text-n-slate-11">
                        {{ $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_HINT') }}
                      </p>

                      <div
                        v-if="telegramPersonalQrCode"
                        class="mt-4 flex min-h-[15rem] items-center justify-center rounded-xl border border-n-weak bg-white p-4"
                      >
                        <img
                          :src="telegramPersonalQrCode"
                          :alt="
                            $t(
                              'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.QR_IMAGE_ALT'
                            )
                          "
                          class="h-auto w-full max-w-[14rem]"
                        />
                      </div>
                      <div
                        v-else
                        class="mt-4 flex min-h-[15rem] items-center justify-center rounded-xl border border-dashed border-n-weak bg-n-alpha-black2 px-4 py-8 text-center text-sm text-n-slate-10"
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
                              value: formatSetupDate(
                                telegramPersonalQrExpiresAt
                              ),
                            }
                          )
                        }}
                      </p>
                    </div>

                    <NextButton
                      class="mt-4 w-full"
                      type="button"
                      outline
                      slate
                      icon="i-lucide-qr-code"
                      :is-loading="isRequestingTelegramPersonalQr"
                      :label="telegramPersonalQrButtonLabel"
                      @click="requestTelegramPersonalQr()"
                    />
                  </div>

                  <div
                    v-if="shouldShowTelegramPersonalCodeRequest"
                    class="flex flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
                  >
                    <div>
                      <p class="text-sm font-semibold text-n-slate-12">
                        {{
                          $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_LOGIN')
                        }}
                      </p>
                      <p class="mt-1.5 text-sm leading-relaxed text-n-slate-11">
                        {{
                          $t(
                            'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE_HINT'
                          )
                        }}
                      </p>
                      <div
                        class="mt-4 flex min-h-[15rem] flex-col items-center justify-center rounded-xl border border-dashed border-n-weak bg-n-alpha-black2 px-6 py-8 text-center"
                      >
                        <p class="text-sm text-n-slate-10">
                          {{
                            $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_HINT')
                          }}
                        </p>
                      </div>
                    </div>

                    <NextButton
                      class="mt-4 w-full"
                      type="button"
                      outline
                      slate
                      icon="i-lucide-key-round"
                      :is-loading="isRequestingTelegramPersonalCode"
                      :label="telegramPersonalRequestButtonLabel"
                      @click.prevent="requestTelegramPersonalCode()"
                    />
                  </div>

                  <form
                    v-else-if="shouldShowTelegramPersonalCodeVerify"
                    class="flex flex-col justify-between rounded-2xl border border-n-weak bg-n-solid-1 p-5 shadow-sm"
                    @submit.prevent="verifyTelegramPersonalCode"
                  >
                    <div class="space-y-3">
                      <p class="text-sm font-semibold text-n-slate-12">
                        {{
                          $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_LOGIN')
                        }}
                      </p>
                      <p class="text-sm leading-relaxed text-n-slate-11">
                        {{
                          $t('INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_HINT')
                        }}
                      </p>
                      <input
                        v-model="telegramPersonalCode"
                        class="!mb-0 w-full rounded-xl border-0 bg-n-alpha-black2 px-4 py-3 text-center font-mono text-lg font-semibold tracking-[0.25em] text-n-slate-12 outline outline-1 outline-offset-[-1px] outline-n-weak focus:outline-n-brand"
                        type="text"
                        inputmode="numeric"
                        autocomplete="one-time-code"
                        :placeholder="
                          $t(
                            'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.CODE_PLACEHOLDER'
                          )
                        "
                      />
                    </div>
                    <div class="mt-4 flex flex-col gap-2">
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
                      <NextButton
                        class="w-full"
                        type="button"
                        ghost
                        slate
                        xs
                        :is-loading="isRequestingTelegramPersonalCode"
                        :label="
                          $t(
                            'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_NEW_CODE'
                          )
                        "
                        @click.prevent="requestTelegramPersonalCode()"
                      />
                    </div>
                  </form>
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
              name: getInboxFlowRouteName(route, 'show'),
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
