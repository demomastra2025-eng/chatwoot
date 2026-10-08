<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue';
import { useStore } from 'vuex';
import { useRoute, useRouter } from 'vue-router';
import { useI18n, I18nT } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Icon from 'next/icon/Icon.vue';
import NextButton from 'next/button/Button.vue';
import LoadingState from 'dashboard/components/widgets/LoadingState.vue';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import globalConstants from 'dashboard/constants/globals.js';
import WhatsappChannel from 'dashboard/api/channel/whatsappChannel';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';
import {
  setupFacebookSdk,
  initWhatsAppEmbeddedSignup,
  createMessageHandler,
  isValidBusinessData,
  embeddedSignupFlowForEvent,
  EMBEDDED_SIGNUP_FLOW,
  isEmbeddedSignupErrorEvent,
  isEmbeddedSignupFinishEvent,
  embeddedSignupSessionData,
  getWhatsAppEmbeddedSignupConfigErrors,
  generateSignupNonce,
  savePendingSignup,
  loadPendingSignup,
  clearPendingSignup,
  isLikelyInAppBrowser,
} from './whatsapp/utils';

const store = useStore();
const router = useRouter();
const route = useRoute();
const { t } = useI18n();

const SIGNUP_TIMEOUT_MS = 10 * 60 * 1000;
// Meta's auth code is short-lived: when FB.login returned it but the
// WA_EMBEDDED_SIGNUP message did not follow (mobile popup tab), complete with
// the code alone and let the server read the shared WABA from the token.
const BUSINESS_INFO_GRACE_MS = 4000;
// Meta's message arrived but the FB.login callback did not.
const AUTH_CODE_GRACE_MS = 15000;
// The tab came back from Meta and nothing arrived: offer to continue.
const RESUME_GRACE_MS = 5000;
const STATUS_POLL_INTERVAL_MS = 3000;
const STATUS_POLL_ATTEMPTS = 40;
const SIGNUP_ATTEMPT_ALREADY_USED = 'signup_attempt_already_used';

const RECOVERY_REASON = {
  WAITING: 'waiting',
  INTERRUPTED: 'interrupted',
  TIMEOUT: 'timeout',
  FAILED: 'failed',
};

// State
const fbSdkLoaded = ref(false);
const isLoadingFacebook = ref(true);
const isProcessing = ref(false);
const processingMessage = ref('');
const authCodeReceived = ref(false);
const authCode = ref(null);
const businessData = ref(null);
const signupFlow = ref(null);
const requestedSignupFlow = ref(EMBEDDED_SIGNUP_FLOW.STANDARD);
const isAuthenticating = ref(false);
const recoveryState = ref(null);
let handleSignupMessage = null;
let signupTimeout = null;
let businessInfoGraceTimeout = null;
let authCodeGraceTimeout = null;
let resumeGraceTimeout = null;
let statusPollTimeout = null;
let statusPollRequest = null;
let attemptSequence = 0;
let currentAttempt = null;
let wasHiddenDuringAttempt = false;
let isUnmounted = false;

const accountId = () => route?.params?.accountId;
const userId = () => store?.getters?.getCurrentUserID;

const clearTimer = timer => {
  if (timer) window.clearTimeout(timer);
  return null;
};

const clearSignupTimeout = () => {
  signupTimeout = clearTimer(signupTimeout);
};

const clearGraceTimers = () => {
  businessInfoGraceTimeout = clearTimer(businessInfoGraceTimeout);
  authCodeGraceTimeout = clearTimer(authCodeGraceTimeout);
  resumeGraceTimeout = clearTimer(resumeGraceTimeout);
};

const stopStatusPolling = () => {
  statusPollTimeout = clearTimer(statusPollTimeout);
  statusPollRequest = null;
};

const cleanupMessageListener = () => {
  if (!handleSignupMessage) return;

  window.removeEventListener('message', handleSignupMessage);
};

const forgetAttempt = () => {
  currentAttempt = null;
  clearPendingSignup(accountId(), userId());
};

const persistAttempt = changes => {
  if (!currentAttempt) return;

  currentAttempt = { ...currentAttempt, ...changes };
  savePendingSignup(accountId(), userId(), currentAttempt);
};

const benefits = computed(() => [
  {
    key: 'EASY_SETUP',
    text: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.BENEFITS.EASY_SETUP'),
  },
  {
    key: 'SECURE_AUTH',
    text: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.BENEFITS.SECURE_AUTH'),
  },
  {
    key: 'AUTO_CONFIG',
    text: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.BENEFITS.AUTO_CONFIG'),
  },
]);

const showLoader = computed(
  () => isLoadingFacebook.value || isAuthenticating.value || isProcessing.value
);

const showInAppBrowserHint = computed(() => isLikelyInAppBrowser());

const recoveryTitle = computed(() => {
  switch (recoveryState.value?.reason) {
    case RECOVERY_REASON.WAITING:
      return t(
        'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.WAITING_TITLE'
      );
    case RECOVERY_REASON.TIMEOUT:
      return t(
        'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.TIMEOUT_TITLE'
      );
    case RECOVERY_REASON.FAILED:
      return t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.FAILED_TITLE');
    default:
      return t(
        'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.INTERRUPTED_TITLE'
      );
  }
});

const recoveryDescription = computed(() => {
  switch (recoveryState.value?.reason) {
    case RECOVERY_REASON.WAITING:
      return t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.WAITING_DESC');
    case RECOVERY_REASON.TIMEOUT:
      return t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.TIMEOUT_DESC');
    case RECOVERY_REASON.FAILED:
      return recoveryState.value.message;
    default:
      return t(
        'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.INTERRUPTED_DESC'
      );
  }
});

const getEmbeddedSignupConfigurationError = () => {
  const missingConfig = getWhatsAppEmbeddedSignupConfigErrors(
    window.chatwootConfig
  );
  if (missingConfig.includes('WHATSAPP_APP_ID')) {
    return t('INBOX.REAUTHORIZE.WHATSAPP_APP_ID_MISSING');
  }
  if (missingConfig.includes('WHATSAPP_CONFIGURATION_ID')) {
    return t('INBOX.REAUTHORIZE.WHATSAPP_CONFIG_ID_MISSING');
  }
  return '';
};

const signupErrorMessageForCode = errorCode => {
  if (errorCode === 'waba_ambiguous') {
    return t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.WABA_AMBIGUOUS');
  }
  if (errorCode === 'waba_not_found') {
    return t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.WABA_NOT_FOUND');
  }
  return t('INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE');
};

const stopAttempt = () => {
  clearSignupTimeout();
  clearGraceTimers();
  stopStatusPolling();
  cleanupMessageListener();
  isProcessing.value = false;
  authCodeReceived.value = false;
  authCode.value = null;
  isAuthenticating.value = false;
  wasHiddenDuringAttempt = false;
};

const openExistingInbox = async inboxId => {
  const safeInboxId = Number(inboxId);
  if (!Number.isInteger(safeInboxId) || safeInboxId <= 0) return false;

  stopAttempt();
  forgetAttempt();
  recoveryState.value = null;
  await store.dispatch('inboxes/get').catch(() => {});
  useAlert(t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.ALREADY_CONNECTED'));
  router.replace({
    name: getInboxFlowRouteName(route, 'show'),
    params: { ...route.params, inboxId: safeInboxId },
  });
  return true;
};

// Error handling
function handleSignupError(data) {
  stopAttempt();
  forgetAttempt();

  const errorMessage =
    data.error ||
    data.message ||
    t('INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE');
  useAlert(errorMessage);
}

// A calm "continue / cancel" state instead of an endless spinner. WAITING keeps
// the current attempt listening, so a late Meta result still completes it.
const showRecovery = (reason, message = '') => {
  const flow = currentAttempt?.flow || requestedSignupFlow.value;
  if (reason === RECOVERY_REASON.WAITING) {
    clearGraceTimers();
  } else {
    stopAttempt();
    forgetAttempt();
  }
  processingMessage.value = '';
  recoveryState.value = { reason, flow, message };
};

const startSignupTimeout = () => {
  clearSignupTimeout();
  signupTimeout = window.setTimeout(() => {
    showRecovery(RECOVERY_REASON.TIMEOUT);
  }, SIGNUP_TIMEOUT_MS);
};

const handleSignupCancellation = () => {
  stopAttempt();
  forgetAttempt();
};

const handleSignupSuccess = inboxData => {
  stopAttempt();
  forgetAttempt();
  recoveryState.value = null;

  if (inboxData && inboxData.id) {
    useAlert(t('INBOX_MGMT.FINISH.MESSAGE'));
    router.replace({
      name: getInboxFlowRouteName(route, 'agents'),
      params: {
        page: 'new',
        inbox_id: inboxData.id,
      },
    });
  } else {
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SUCCESS_FALLBACK'));
    router.replace({
      name: getInboxFlowRouteName(route, 'list'),
    });
  }
};

// Ask the server what happened to an attempt whose completion request may have
// been cut off (suspended tab) or which a reloaded tab no longer tracks.
async function pollAttemptStatus(attempt, attemptsLeft = STATUS_POLL_ATTEMPTS) {
  statusPollTimeout = clearTimer(statusPollTimeout);
  if (isUnmounted || !attempt) return;

  isProcessing.value = true;
  recoveryState.value = null;
  processingMessage.value = t(
    'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RESUMING'
  );

  const request = {};
  statusPollRequest = request;
  let status = null;
  try {
    const response = await WhatsappChannel.getEmbeddedSignupAttemptStatus({
      signupNonce: attempt.nonce,
    });
    status = response?.data || {};
  } catch {
    status = { status: 'network_error' };
  }
  if (isUnmounted || statusPollRequest !== request) return;
  statusPollRequest = null;

  if (status.status === 'completed') {
    await store.dispatch('inboxes/get').catch(() => {});
    handleSignupSuccess({ id: status.inbox_id });
    return;
  }

  if (status.status === 'failed') {
    if (status.error_code === 'already_connected' && status.inbox_id) {
      if (await openExistingInbox(status.inbox_id)) return;
    }

    showRecovery(
      RECOVERY_REASON.FAILED,
      signupErrorMessageForCode(status.error_code)
    );
    return;
  }

  const stillRunning = ['processing', 'network_error'].includes(status.status);
  if (stillRunning && attemptsLeft > 1) {
    statusPollTimeout = window.setTimeout(() => {
      pollAttemptStatus(attempt, attemptsLeft - 1);
    }, STATUS_POLL_INTERVAL_MS);
    return;
  }

  showRecovery(RECOVERY_REASON.INTERRUPTED);
}

// Signup flow
const completeSignupFlow = async businessDataParam => {
  if (isProcessing.value) return;

  if (!authCodeReceived.value || !authCode.value) {
    handleSignupError({
      error: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.AUTH_NOT_COMPLETED'),
    });
    return;
  }

  clearGraceTimers();
  recoveryState.value = null;
  isProcessing.value = true;
  const authorizationCode = authCode.value;
  authCode.value = null;
  processingMessage.value = t(
    'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.PROCESSING'
  );
  const attempt = currentAttempt;
  persistAttempt({ codeSubmitted: true });

  try {
    const params = businessDataParam
      ? {
          code: authorizationCode,
          signup_type: signupFlow.value,
          business_id: businessDataParam.business_id || '',
          waba_id: businessDataParam.waba_id,
          phone_number_id: businessDataParam?.phone_number_id || '',
        }
      : { code: authorizationCode, signup_type: requestedSignupFlow.value };
    if (attempt) params.signup_nonce = attempt.nonce;

    const responseData = await store.dispatch(
      'inboxes/createWhatsAppEmbeddedSignup',
      params
    );

    authCode.value = null;
    handleSignupSuccess(responseData);
  } catch (error) {
    const errorCode = error?.response?.data?.error_code;
    const existingInboxId = error?.response?.data?.inbox_id;
    if (errorCode === 'already_connected') {
      const opened = existingInboxId
        ? await openExistingInbox(existingInboxId)
        : false;
      if (!opened) {
        handleSignupError({
          error: t('INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE'),
        });
      }
      return;
    }

    // The request may have reached the server although this (mobile) tab lost
    // the response; the attempt status tells what actually happened.
    if (
      attempt &&
      (!error?.response || errorCode === SIGNUP_ATTEMPT_ALREADY_USED)
    ) {
      isProcessing.value = false;
      pollAttemptStatus(attempt);
      return;
    }

    const errorMessage =
      parseAPIErrorResponse(error) || signupErrorMessageForCode(errorCode);
    if (businessDataParam) {
      handleSignupError({ error: errorMessage });
    } else {
      showRecovery(RECOVERY_REASON.FAILED, errorMessage);
    }
  }
};

const scheduleCodeOnlyCompletion = sequence => {
  businessInfoGraceTimeout = clearTimer(businessInfoGraceTimeout);
  businessInfoGraceTimeout = window.setTimeout(() => {
    businessInfoGraceTimeout = null;
    if (sequence !== attemptSequence || isProcessing.value) return;
    if (!authCodeReceived.value || !authCode.value || businessData.value) {
      return;
    }
    completeSignupFlow(null);
  }, BUSINESS_INFO_GRACE_MS);
};

const scheduleAuthCodeGrace = sequence => {
  authCodeGraceTimeout = clearTimer(authCodeGraceTimeout);
  authCodeGraceTimeout = window.setTimeout(() => {
    authCodeGraceTimeout = null;
    if (sequence !== attemptSequence || isProcessing.value) return;
    if (authCodeReceived.value || !isAuthenticating.value) return;
    showRecovery(RECOVERY_REASON.WAITING);
  }, AUTH_CODE_GRACE_MS);
};

// Message handling
const handleEmbeddedSignupData = async data => {
  WhatsappChannel.logEmbeddedSignupSession(
    embeddedSignupSessionData(data)
  ).catch(() => {});

  if (isEmbeddedSignupFinishEvent(data)) {
    const businessDataLocal = data.data;
    const flow = embeddedSignupFlowForEvent(data);

    if (flow !== requestedSignupFlow.value) {
      handleSignupError({
        error: t(
          'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.INVALID_BUSINESS_DATA'
        ),
      });
      return;
    }

    if (isValidBusinessData(businessDataLocal, flow)) {
      businessData.value = businessDataLocal;
      signupFlow.value = flow;
      if (authCodeReceived.value && authCode.value) {
        await completeSignupFlow(businessDataLocal);
      } else {
        processingMessage.value = t(
          'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.WAITING_FOR_AUTH'
        );
        scheduleAuthCodeGrace(attemptSequence);
      }
    } else {
      handleSignupError({
        error: t(
          'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.INVALID_BUSINESS_DATA'
        ),
      });
    }
  } else if (isEmbeddedSignupErrorEvent(data)) {
    const details = data.data || data;
    handleSignupError({
      error:
        details.error_message ||
        t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SIGNUP_ERROR'),
      error_id: details.error_code || data.error_id,
      session_id: details.session_id || data.session_id,
    });
  } else if (data.event === 'CANCEL') {
    handleSignupCancellation();
  }
};

handleSignupMessage = createMessageHandler(handleEmbeddedSignupData);

function setupMessageListener() {
  cleanupMessageListener();
  window.addEventListener('message', handleSignupMessage);
}

// Registers the attempt locally and on the server. Runs right after FB.login
// was called, so the popup still opens synchronously from the tap.
const beginAttempt = flow => {
  let nonce = null;
  try {
    nonce = generateSignupNonce();
  } catch {
    nonce = null;
  }
  if (!nonce) {
    currentAttempt = null;
    return;
  }

  currentAttempt = {
    nonce,
    flow,
    startedAt: Date.now(),
    codeSubmitted: false,
  };
  savePendingSignup(accountId(), userId(), currentAttempt);
  WhatsappChannel.registerEmbeddedSignupAttempt({
    signupNonce: nonce,
    signupType: flow,
  }).catch(() => {});
};

const handleLoginResult = async (sequence, loginPromise) => {
  try {
    const code = await loginPromise;
    if (sequence !== attemptSequence) return;

    clearGraceTimers();
    recoveryState.value = null;
    authCode.value = code;
    authCodeReceived.value = true;
    processingMessage.value = t(
      'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.WAITING_FOR_BUSINESS_INFO'
    );

    if (businessData.value) {
      completeSignupFlow(businessData.value);
    } else {
      scheduleCodeOnlyCompletion(sequence);
    }
  } catch (error) {
    if (sequence !== attemptSequence) return;

    recoveryState.value = null;
    if (error.message === 'Login cancelled') {
      handleSignupCancellation();
      useAlert(t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.CANCELLED'));
    } else {
      handleSignupError({
        error:
          error.message ||
          t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SDK_LOAD_ERROR'),
      });
    }
  }
};

// Keep FB.login in the click task: nothing may be awaited before it, or mobile
// browsers block the Meta popup.
const launchEmbeddedSignup = (flow = EMBEDDED_SIGNUP_FLOW.STANDARD) => {
  if (isProcessing.value) return undefined;
  if (isAuthenticating.value && !recoveryState.value) return undefined;

  const configurationError = getEmbeddedSignupConfigurationError();
  if (configurationError) {
    handleSignupError({ error: configurationError });
    return undefined;
  }

  if (!fbSdkLoaded.value) {
    handleSignupError({
      error: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SDK_LOAD_ERROR'),
    });
    return undefined;
  }

  attemptSequence += 1;
  const sequence = attemptSequence;
  clearGraceTimers();
  stopStatusPolling();
  recoveryState.value = null;
  wasHiddenDuringAttempt = false;
  authCode.value = null;
  authCodeReceived.value = false;
  businessData.value = null;
  signupFlow.value = null;
  requestedSignupFlow.value = flow;
  setupMessageListener();
  isAuthenticating.value = true;
  processingMessage.value = t(
    'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.AUTH_PROCESSING'
  );

  startSignupTimeout();
  let loginPromise;
  try {
    loginPromise = initWhatsAppEmbeddedSignup(
      window.chatwootConfig?.whatsappConfigurationId,
      flow
    );
  } catch (error) {
    loginPromise = Promise.reject(error);
  }
  beginAttempt(flow);

  return handleLoginResult(sequence, loginPromise);
};

const continueSignup = () => {
  launchEmbeddedSignup(recoveryState.value?.flow || requestedSignupFlow.value);
};

const cancelRecovery = () => {
  attemptSequence += 1;
  stopAttempt();
  forgetAttempt();
  businessData.value = null;
  signupFlow.value = null;
  recoveryState.value = null;
};

const resumePendingAttempt = () => {
  const pending = loadPendingSignup(accountId(), userId());
  if (!pending) return;

  currentAttempt = pending;
  requestedSignupFlow.value = pending.flow;
  pollAttemptStatus(pending);
};

const handlePageVisible = () => {
  if (statusPollTimeout && currentAttempt) {
    pollAttemptStatus(currentAttempt);
    return;
  }
  if (!isAuthenticating.value || isProcessing.value || recoveryState.value) {
    return;
  }
  if (!wasHiddenDuringAttempt) return;

  wasHiddenDuringAttempt = false;
  const sequence = attemptSequence;
  if (authCodeReceived.value) {
    // Timers may have been frozen while the tab was in the background.
    if (!businessInfoGraceTimeout) scheduleCodeOnlyCompletion(sequence);
    return;
  }

  resumeGraceTimeout = clearTimer(resumeGraceTimeout);
  resumeGraceTimeout = window.setTimeout(() => {
    resumeGraceTimeout = null;
    if (sequence !== attemptSequence || isProcessing.value) return;
    if (authCodeReceived.value || !isAuthenticating.value) return;
    if (recoveryState.value) return;
    showRecovery(RECOVERY_REASON.WAITING);
  }, RESUME_GRACE_MS);
};

const handleVisibilityChange = () => {
  if (document.visibilityState === 'hidden') {
    if (isAuthenticating.value && !isProcessing.value) {
      wasHiddenDuringAttempt = true;
    }
    return;
  }
  handlePageVisible();
};

const handlePageShow = event => {
  if (!event?.persisted) return;

  // Restored from the back/forward cache: the in-memory FB.login callback may be
  // gone, so treat it like a return from Meta or like a reload.
  if (isAuthenticating.value || isProcessing.value) {
    wasHiddenDuringAttempt = true;
    handlePageVisible();
  } else if (!recoveryState.value) {
    resumePendingAttempt();
  }
};

onMounted(async () => {
  document.addEventListener('visibilitychange', handleVisibilityChange);
  window.addEventListener('pageshow', handlePageShow);
  resumePendingAttempt();

  const configurationError = getEmbeddedSignupConfigurationError();
  if (configurationError) {
    handleSignupError({ error: configurationError });
    isLoadingFacebook.value = false;
    return;
  }

  try {
    await setupFacebookSdk(
      window.chatwootConfig?.whatsappAppId,
      window.chatwootConfig?.whatsappApiVersion
    );
    fbSdkLoaded.value = true;
  } catch {
    handleSignupError({
      error: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SDK_LOAD_ERROR'),
    });
  } finally {
    isLoadingFacebook.value = false;
  }
});

onBeforeUnmount(() => {
  isUnmounted = true;
  document.removeEventListener('visibilitychange', handleVisibilityChange);
  window.removeEventListener('pageshow', handlePageShow);
  clearSignupTimeout();
  clearGraceTimers();
  stopStatusPolling();
  cleanupMessageListener();
});
</script>

<template>
  <div class="h-full">
    <div
      v-if="recoveryState"
      class="flex flex-col gap-4 rounded-xl border border-n-weak bg-n-alpha-1 p-4"
      data-testid="whatsapp-signup-recovery"
    >
      <div class="flex flex-col gap-2">
        <h3 class="text-base font-medium text-n-slate-12">
          {{ recoveryTitle }}
        </h3>
        <p class="text-sm leading-6 text-n-slate-11">
          {{ recoveryDescription }}
        </p>
        <p class="text-sm leading-6 text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.TIP') }}
        </p>
      </div>
      <div class="flex flex-col gap-2 sm:flex-row">
        <NextButton
          class="w-full sm:w-auto"
          :disabled="!fbSdkLoaded"
          :is-loading="isLoadingFacebook"
          data-testid="whatsapp-signup-continue"
          @click="continueSignup"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.CONTINUE') }}
        </NextButton>
        <NextButton
          faded
          slate
          class="w-full sm:w-auto"
          data-testid="whatsapp-signup-cancel"
          @click="cancelRecovery"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.RECOVERY.CANCEL') }}
        </NextButton>
      </div>
    </div>

    <LoadingState v-else-if="showLoader" :message="processingMessage" />

    <div v-else>
      <div class="flex flex-col items-start mb-6 text-start">
        <div class="flex justify-start mb-6">
          <div
            class="flex size-11 items-center justify-center rounded-full bg-n-alpha-2"
          >
            <Icon icon="i-woot-whatsapp" class="text-n-slate-10 size-6" />
          </div>
        </div>

        <h3 class="mb-2 text-base font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.TITLE') }}
        </h3>
        <p class="text-sm leading-[24px] text-n-slate-12">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.DESC') }}
        </p>
      </div>

      <p
        v-if="showInAppBrowserHint"
        class="mb-6 rounded-xl border border-n-amber-4 bg-n-amber-3 p-3 text-sm text-n-amber-11"
        data-testid="whatsapp-signup-in-app-browser"
      >
        {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.IN_APP_BROWSER') }}
      </p>

      <div class="flex flex-col gap-2 mb-6">
        <div
          v-for="benefit in benefits"
          :key="benefit.key"
          class="flex gap-2 items-center text-sm text-n-slate-11"
        >
          <Icon icon="i-lucide-check" class="text-n-slate-11 size-4" />
          {{ benefit.text }}
        </div>
      </div>

      <div class="flex flex-col gap-2 mb-6">
        <I18nT
          keypath="INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.LEARN_MORE.TEXT"
          tag="span"
          class="text-sm text-n-slate-11"
        >
          <template #link>
            <a
              :href="globalConstants.WHATSAPP_EMBEDDED_SIGNUP_DOCS_URL"
              target="_blank"
              rel="noopener noreferrer"
              class="text-link"
            >
              {{
                $t(
                  'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.LEARN_MORE.LINK_TEXT'
                )
              }}
            </a>
          </template>
        </I18nT>
      </div>

      <div class="flex flex-col gap-2 mt-4">
        <NextButton
          :disabled="!fbSdkLoaded || isAuthenticating"
          :is-loading="isAuthenticating"
          faded
          slate
          class="w-full"
          @click="launchEmbeddedSignup(EMBEDDED_SIGNUP_FLOW.STANDARD)"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.STANDARD_BUTTON') }}
        </NextButton>
        <NextButton
          :disabled="!fbSdkLoaded || isAuthenticating"
          :is-loading="isAuthenticating"
          faded
          slate
          class="w-full"
          @click="launchEmbeddedSignup(EMBEDDED_SIGNUP_FLOW.COEXISTENCE)"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.COEXISTENCE_BUTTON') }}
        </NextButton>
      </div>
    </div>
  </div>
</template>
