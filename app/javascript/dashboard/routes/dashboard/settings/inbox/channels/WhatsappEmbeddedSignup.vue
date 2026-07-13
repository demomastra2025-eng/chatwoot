<script setup>
import { ref, computed, onBeforeUnmount } from 'vue';
import { useStore } from 'vuex';
import { useRoute, useRouter } from 'vue-router';
import { useI18n, I18nT } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Icon from 'next/icon/Icon.vue';
import NextButton from 'next/button/Button.vue';
import LoadingState from 'dashboard/components/widgets/LoadingState.vue';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import globalConstants from 'dashboard/constants/globals.js';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';
import {
  setupFacebookSdk,
  initWhatsAppEmbeddedSignup,
  createMessageHandler,
  isValidBusinessData,
  isEmbeddedSignupErrorEvent,
  isEmbeddedSignupFinishEvent,
  getWhatsAppEmbeddedSignupConfigErrors,
} from './whatsapp/utils';

const store = useStore();
const router = useRouter();
const route = useRoute();
const { t } = useI18n();

const SIGNUP_TIMEOUT_MS = 10 * 60 * 1000;

// State
const fbSdkLoaded = ref(false);
const isProcessing = ref(false);
const processingMessage = ref('');
const authCodeReceived = ref(false);
const authCode = ref(null);
const businessData = ref(null);
const isAuthenticating = ref(false);
let handleSignupMessage = null;
let signupTimeout = null;

const clearSignupTimeout = () => {
  if (!signupTimeout) return;

  window.clearTimeout(signupTimeout);
  signupTimeout = null;
};

const cleanupMessageListener = () => {
  if (!handleSignupMessage) return;

  window.removeEventListener('message', handleSignupMessage);
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

const showLoader = computed(() => isAuthenticating.value || isProcessing.value);

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

// Error handling
function handleSignupError(data) {
  clearSignupTimeout();
  isProcessing.value = false;
  authCodeReceived.value = false;
  isAuthenticating.value = false;
  cleanupMessageListener();

  const errorMessage =
    data.error ||
    data.message ||
    t('INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE');
  useAlert(errorMessage);
}

const startSignupTimeout = () => {
  clearSignupTimeout();
  signupTimeout = window.setTimeout(() => {
    handleSignupError({
      error: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SIGNUP_ERROR'),
    });
  }, SIGNUP_TIMEOUT_MS);
};

const handleSignupCancellation = () => {
  clearSignupTimeout();
  isProcessing.value = false;
  authCodeReceived.value = false;
  isAuthenticating.value = false;
  cleanupMessageListener();
};

const handleSignupSuccess = inboxData => {
  clearSignupTimeout();
  isProcessing.value = false;
  isAuthenticating.value = false;
  cleanupMessageListener();

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

// Signup flow
const completeSignupFlow = async businessDataParam => {
  if (isProcessing.value) return;

  if (!authCodeReceived.value || !authCode.value) {
    handleSignupError({
      error: t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.AUTH_NOT_COMPLETED'),
    });
    return;
  }

  isProcessing.value = true;
  const authorizationCode = authCode.value;
  authCode.value = null;
  processingMessage.value = t(
    'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.PROCESSING'
  );

  try {
    const params = {
      code: authorizationCode,
      business_id: businessDataParam.business_id,
      waba_id: businessDataParam.waba_id,
      phone_number_id: businessDataParam?.phone_number_id || '',
    };

    const responseData = await store.dispatch(
      'inboxes/createWhatsAppEmbeddedSignup',
      params
    );

    authCode.value = null;
    handleSignupSuccess(responseData);
  } catch (error) {
    const errorMessage =
      parseAPIErrorResponse(error) ||
      t('INBOX_MGMT.ADD.WHATSAPP.API.ERROR_MESSAGE');
    handleSignupError({ error: errorMessage });
  }
};

// Message handling
const handleEmbeddedSignupData = async data => {
  if (isEmbeddedSignupFinishEvent(data)) {
    const businessDataLocal = data.data;

    if (isValidBusinessData(businessDataLocal)) {
      businessData.value = businessDataLocal;
      if (authCodeReceived.value && authCode.value) {
        await completeSignupFlow(businessDataLocal);
      } else {
        processingMessage.value = t(
          'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.WAITING_FOR_AUTH'
        );
      }
    } else {
      handleSignupError({
        error: t(
          'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.INVALID_BUSINESS_DATA'
        ),
      });
    }
  } else if (data.event === 'CANCEL') {
    handleSignupCancellation();
  } else if (isEmbeddedSignupErrorEvent(data)) {
    handleSignupError({
      error:
        data.error_message ||
        t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SIGNUP_ERROR'),
      error_id: data.error_id,
      session_id: data.session_id,
    });
  }
};

handleSignupMessage = createMessageHandler(handleEmbeddedSignupData);

function setupMessageListener() {
  cleanupMessageListener();
  window.addEventListener('message', handleSignupMessage);
}

const launchEmbeddedSignup = async () => {
  const configurationError = getEmbeddedSignupConfigurationError();
  if (configurationError) {
    handleSignupError({ error: configurationError });
    return;
  }

  try {
    authCode.value = null;
    authCodeReceived.value = false;
    businessData.value = null;
    setupMessageListener();
    isAuthenticating.value = true;
    processingMessage.value = t(
      'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.AUTH_PROCESSING'
    );

    await setupFacebookSdk(
      window.chatwootConfig?.whatsappAppId,
      window.chatwootConfig?.whatsappApiVersion
    );
    fbSdkLoaded.value = true;

    startSignupTimeout();
    const code = await initWhatsAppEmbeddedSignup(
      window.chatwootConfig?.whatsappConfigurationId
    );

    authCode.value = code;
    authCodeReceived.value = true;
    processingMessage.value = t(
      'INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.WAITING_FOR_BUSINESS_INFO'
    );

    if (businessData.value) {
      completeSignupFlow(businessData.value);
    }
  } catch (error) {
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

onBeforeUnmount(() => {
  clearSignupTimeout();
  cleanupMessageListener();
});
</script>

<template>
  <div class="h-full">
    <LoadingState v-if="showLoader" :message="processingMessage" />

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

      <div class="flex mt-4">
        <NextButton
          :disabled="isAuthenticating"
          :is-loading="isAuthenticating"
          faded
          slate
          class="w-full"
          @click="launchEmbeddedSignup"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SUBMIT_BUTTON') }}
        </NextButton>
      </div>
    </div>
  </div>
</template>
