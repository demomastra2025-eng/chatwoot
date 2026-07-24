<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { useStore } from 'vuex';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import WhatsappChannel from 'dashboard/api/channel/whatsappChannel';
import NextButton from 'next/button/Button.vue';
import InboxReconnectionRequired from '../../components/InboxReconnectionRequired.vue';
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
} from './utils';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
  whatsappRegistrationIncomplete: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const store = useStore();

const SIGNUP_TIMEOUT_MS = 10 * 60 * 1000;

const isRequestingAuthorization = ref(false);
const isSubmittingReauthorization = ref(false);
const isLoadingFacebook = ref(true);
const authCode = ref(null);
const signupBusinessData = ref(null);
const signupFlow = ref(null);
const selectedReauthorizationFlow = ref(null);
let signupMessageHandler = null;
let signupTimeout = null;

const whatsappAppId = computed(() => window.chatwootConfig?.whatsappAppId);
const whatsappConfigurationId = computed(
  () => window.chatwootConfig?.whatsappConfigurationId
);
const persistedReauthorizationFlow = computed(() => {
  const flow = props.inbox.provider_config?.embedded_signup_flow;
  return Object.values(EMBEDDED_SIGNUP_FLOW).includes(flow) ? flow : null;
});
const reauthorizationFlow = computed(
  () => selectedReauthorizationFlow.value || persistedReauthorizationFlow.value
);
const requiresFlowSelection = computed(
  () => !persistedReauthorizationFlow.value
);

const actionLabel = computed(() => {
  if (props.whatsappRegistrationIncomplete) {
    return t('INBOX_MGMT.COMPLETE_REGISTRATION');
  }
  return t('INBOX.REAUTHORIZE.BUTTON_TEXT');
});

const tokenExpiresSoon = computed(
  () =>
    !props.inbox.reauthorization_required &&
    !props.inbox.requires_reauthorization &&
    props.inbox.provider_config?.token_health?.status === 'expiring'
);

const description = computed(() => {
  if (props.whatsappRegistrationIncomplete) {
    return t('INBOX_MGMT.WHATSAPP_REGISTRATION_INCOMPLETE');
  }
  if (tokenExpiresSoon.value) {
    return t('INBOX.REAUTHORIZE.EXPIRING_DESCRIPTION');
  }
  return t('INBOX.REAUTHORIZE.PRESERVE_DATA_DESCRIPTION');
});

const getConfigurationError = () => {
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

const removeSignupMessageListener = () => {
  if (!signupMessageHandler) return;

  window.removeEventListener('message', signupMessageHandler);
  signupMessageHandler = null;
};

const clearSignupTimeout = () => {
  if (!signupTimeout) return;

  window.clearTimeout(signupTimeout);
  signupTimeout = null;
};

function resetSignupState() {
  clearSignupTimeout();
  authCode.value = null;
  signupBusinessData.value = null;
  signupFlow.value = null;
  selectedReauthorizationFlow.value = null;
  isRequestingAuthorization.value = false;
  isSubmittingReauthorization.value = false;
  removeSignupMessageListener();
}

const startSignupTimeout = () => {
  clearSignupTimeout();
  signupTimeout = window.setTimeout(() => {
    resetSignupState();
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SIGNUP_ERROR'));
  }, SIGNUP_TIMEOUT_MS);
};

const reauthorizeWhatsApp = async params => {
  isRequestingAuthorization.value = true;

  try {
    const updatedInbox = await store.dispatch('inboxes/reauthorizeWhatsApp', {
      inboxId: props.inbox.id,
      ...params,
    });

    if (updatedInbox?.id) {
      useAlert(t('INBOX.REAUTHORIZE.SUCCESS'));
    } else {
      useAlert(t('INBOX.REAUTHORIZE.ERROR'));
    }
    return updatedInbox;
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        error?.response?.data?.error ||
        error.message ||
        t('INBOX.REAUTHORIZE.ERROR')
    );
    throw error;
  } finally {
    isRequestingAuthorization.value = false;
  }
};

const completeReauthorizationIfReady = async () => {
  if (isSubmittingReauthorization.value || !authCode.value) return;

  const businessData = signupBusinessData.value;
  const flow = signupFlow.value;
  if (!businessData || !isValidBusinessData(businessData, flow)) return;

  isSubmittingReauthorization.value = true;
  const authorizationCode = authCode.value;
  authCode.value = null;

  try {
    await reauthorizeWhatsApp({
      code: authorizationCode,
      signup_type: flow,
      business_id: businessData.business_id || '',
      waba_id: businessData.waba_id,
      phone_number_id: businessData.phone_number_id || '',
    });
  } catch {
    // The reauthorization action already surfaced a user-friendly error.
  } finally {
    resetSignupState();
  }
};

const handleEmbeddedSignupEvents = async data => {
  if (!data || typeof data !== 'object') {
    return;
  }

  WhatsappChannel.logEmbeddedSignupSession(
    embeddedSignupSessionData(data)
  ).catch(() => {});

  if (isEmbeddedSignupFinishEvent(data)) {
    const businessData = data.data;
    const flow = embeddedSignupFlowForEvent(data);

    if (
      flow === reauthorizationFlow.value &&
      isValidBusinessData(businessData, flow)
    ) {
      signupBusinessData.value = businessData;
      signupFlow.value = flow;
      await completeReauthorizationIfReady();
    } else {
      useAlert(
        t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.INVALID_BUSINESS_DATA')
      );
      resetSignupState();
    }
  } else if (isEmbeddedSignupErrorEvent(data)) {
    const details = data.data || data;
    resetSignupState();
    useAlert(
      details.error_message ||
        t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.SIGNUP_ERROR')
    );
  } else if (data.event === 'CANCEL') {
    resetSignupState();
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.CANCELLED'));
  }
};

const startEmbeddedSignup = () => {
  removeSignupMessageListener();
  authCode.value = null;
  signupBusinessData.value = null;
  signupFlow.value = null;
  signupMessageHandler = createMessageHandler(data =>
    handleEmbeddedSignupEvents(data)
  );
  window.addEventListener('message', signupMessageHandler);
  startSignupTimeout();
};

const handleLoginAndReauthorize = async () => {
  const configurationError = getConfigurationError();
  if (configurationError) throw new Error(configurationError);

  try {
    startEmbeddedSignup();
    authCode.value = await initWhatsAppEmbeddedSignup(
      whatsappConfigurationId.value,
      reauthorizationFlow.value
    );
    await completeReauthorizationIfReady();
  } catch (error) {
    resetSignupState();
    throw error;
  }
};

const requestAuthorization = async requestedFlow => {
  if (isRequestingAuthorization.value || isSubmittingReauthorization.value) {
    return;
  }

  const flow = requestedFlow || persistedReauthorizationFlow.value;
  if (!Object.values(EMBEDDED_SIGNUP_FLOW).includes(flow)) {
    useAlert(t('INBOX.REAUTHORIZE.FLOW_SELECTION_REQUIRED'));
    return;
  }

  if (isLoadingFacebook.value) {
    useAlert(t('INBOX.REAUTHORIZE.LOADING_FACEBOOK'));
    return;
  }

  selectedReauthorizationFlow.value = flow;
  isRequestingAuthorization.value = true;
  try {
    await handleLoginAndReauthorize();
  } catch (error) {
    useAlert(
      error.message === 'Login cancelled'
        ? t('INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.CANCELLED')
        : error.message || t('INBOX.REAUTHORIZE.CONFIGURATION_ERROR')
    );
  } finally {
    if (!signupMessageHandler) {
      isRequestingAuthorization.value = false;
    }
  }
};

onMounted(async () => {
  try {
    const configurationError = getConfigurationError();
    if (configurationError) {
      useAlert(configurationError);
      return;
    }

    await setupFacebookSdk(
      whatsappAppId.value,
      window.chatwootConfig?.whatsappApiVersion
    );
  } catch (error) {
    useAlert(t('INBOX.REAUTHORIZE.FACEBOOK_LOAD_ERROR'));
  } finally {
    isLoadingFacebook.value = false;
  }
});

onUnmounted(() => {
  resetSignupState();
});

// Expose requestAuthorization function for parent components
defineExpose({
  requestAuthorization,
});
</script>

<template>
  <div
    v-if="requiresFlowSelection"
    class="mx-6 flex flex-col gap-3 rounded-xl border border-n-weak bg-n-alpha-1 p-4"
  >
    <p class="text-sm text-n-slate-11">{{ description }}</p>
    <p class="text-sm font-medium text-n-slate-12">
      {{ $t('INBOX.REAUTHORIZE.FLOW_SELECTION_REQUIRED') }}
    </p>
    <div class="flex flex-col gap-2 sm:flex-row">
      <NextButton
        faded
        slate
        :disabled="isRequestingAuthorization"
        :is-loading="isRequestingAuthorization"
        @click="requestAuthorization(EMBEDDED_SIGNUP_FLOW.STANDARD)"
      >
        {{ $t('INBOX.REAUTHORIZE.STANDARD_FLOW_BUTTON') }}
      </NextButton>
      <NextButton
        faded
        slate
        :disabled="isRequestingAuthorization"
        :is-loading="isRequestingAuthorization"
        @click="requestAuthorization(EMBEDDED_SIGNUP_FLOW.COEXISTENCE)"
      >
        {{ $t('INBOX.REAUTHORIZE.COEXISTENCE_FLOW_BUTTON') }}
      </NextButton>
    </div>
  </div>
  <InboxReconnectionRequired
    v-else
    class="mx-6"
    :is-loading="isRequestingAuthorization"
    :action-label="actionLabel"
    :description="description"
    @reauthorize="requestAuthorization"
  />
</template>
