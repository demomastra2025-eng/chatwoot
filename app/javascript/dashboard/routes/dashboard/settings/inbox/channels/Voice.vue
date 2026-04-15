<script setup>
import { reactive, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required, requiredIf } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { isPhoneE164 } from 'shared/helpers/Validators';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';

import PageHeader from '../../SettingsSubPageHeader.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import ChannelSelector from 'dashboard/components/ChannelSelector.vue';

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();

const PROVIDER_TYPES = {
  KAZAKHSTAN: 'kazakhstan',
  TWILIO: 'twilio',
};

const kazakhstanState = reactive({
  phoneNumber: '',
  numberRef: '',
  appRef: '',
  trunkRef: '',
  routingMode: 'operator',
  aiAppRef: '',
  operatorAgentAor: '',
  fallbackMessage: '',
});

const twilioState = reactive({
  phoneNumber: '',
  accountSid: '',
  authToken: '',
  apiKeySid: '',
  apiKeySecret: '',
});

const uiFlags = useMapGetter('inboxes/getUIFlags');

const selectedProvider = computed(() => {
  return Object.values(PROVIDER_TYPES).includes(route.query.provider)
    ? route.query.provider
    : '';
});

const showProviderSelection = computed(() => !selectedProvider.value);

const availableProviders = computed(() => [
  {
    key: PROVIDER_TYPES.KAZAKHSTAN,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KAZAKHSTAN'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KAZAKHSTAN_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
  },
  {
    key: PROVIDER_TYPES.TWILIO,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.TWILIO'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.TWILIO_DESC'),
    icon: 'i-woot-twilio',
  },
]);

const selectedProviderCard = computed(() => {
  return (
    availableProviders.value.find(
      provider => provider.key === selectedProvider.value
    ) || null
  );
});

const kazakhstanValidationRules = computed(() => ({
  phoneNumber: { required, isPhoneE164 },
  numberRef: { required },
  routingMode: { required },
  appRef: {
    required: requiredIf(() => kazakhstanState.routingMode === 'app'),
  },
  aiAppRef: {
    required: requiredIf(() => kazakhstanState.routingMode === 'ai'),
  },
  operatorAgentAor: {
    required: requiredIf(() => kazakhstanState.routingMode === 'operator'),
  },
}));

const twilioValidationRules = computed(() => ({
  phoneNumber: { required, isPhoneE164 },
  accountSid: { required },
  authToken: { required },
  apiKeySid: { required },
  apiKeySecret: { required },
}));

const kazakhstanV$ = useVuelidate(kazakhstanValidationRules, kazakhstanState);
const twilioV$ = useVuelidate(twilioValidationRules, twilioState);

const isKazakhstanSubmitDisabled = computed(() => kazakhstanV$.value.$invalid);
const isTwilioSubmitDisabled = computed(() => twilioV$.value.$invalid);

const routingOptions = computed(() => [
  {
    value: 'operator',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.OPERATOR'),
  },
  {
    value: 'app',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.APP'),
  },
  {
    value: 'ai',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.AI'),
  },
  {
    value: 'reject',
    label: t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.MODE.REJECT'),
  },
]);

const kazakhstanFormErrors = computed(() => ({
  phoneNumber: kazakhstanV$.value.phoneNumber?.$error
    ? t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.ERROR')
    : '',
  numberRef: kazakhstanV$.value.numberRef?.$error
    ? t('INBOX_MGMT.ADD.VOICE.FONOSTER.NUMBER_REF.REQUIRED')
    : '',
  appRef: kazakhstanV$.value.appRef?.$error
    ? t('INBOX_MGMT.ADD.VOICE.FONOSTER.APP_REF.REQUIRED')
    : '',
  aiAppRef: kazakhstanV$.value.aiAppRef?.$error
    ? t('INBOX_MGMT.ADD.VOICE.FONOSTER.AI_APP_REF.REQUIRED')
    : '',
  operatorAgentAor: kazakhstanV$.value.operatorAgentAor?.$error
    ? t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_AOR.REQUIRED')
    : '',
}));

const twilioFormErrors = computed(() => ({
  phoneNumber: twilioV$.value.phoneNumber?.$error
    ? t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.ERROR')
    : '',
  accountSid: twilioV$.value.accountSid?.$error
    ? t('INBOX_MGMT.ADD.VOICE.TWILIO.ACCOUNT_SID.REQUIRED')
    : '',
  authToken: twilioV$.value.authToken?.$error
    ? t('INBOX_MGMT.ADD.VOICE.TWILIO.AUTH_TOKEN.REQUIRED')
    : '',
  apiKeySid: twilioV$.value.apiKeySid?.$error
    ? t('INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SID.REQUIRED')
    : '',
  apiKeySecret: twilioV$.value.apiKeySecret?.$error
    ? t('INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SECRET.REQUIRED')
    : '',
}));

function selectProvider(provider) {
  router.push({
    name: route.name,
    params: route.params,
    query: { provider },
  });
}

function resetProviderSelection() {
  router.push({
    name: route.name,
    params: route.params,
    query: {},
  });
}

function getKazakhstanProviderConfig() {
  return {
    number_ref: kazakhstanState.numberRef,
    app_ref: kazakhstanState.appRef,
    trunk_ref: kazakhstanState.trunkRef,
    routing_mode: kazakhstanState.routingMode,
    ai_app_ref: kazakhstanState.aiAppRef,
    operator_agent_aor: kazakhstanState.operatorAgentAor,
    fallback_mode: 'reject',
    fallback_message: kazakhstanState.fallbackMessage,
  };
}

function handleCreateError(error) {
  useAlert(
    error.response?.data?.message || t('INBOX_MGMT.ADD.VOICE.API.ERROR_MESSAGE')
  );
}

async function createKazakhstanChannel() {
  const isFormValid = await kazakhstanV$.value.$validate();
  if (!isFormValid) return;

  try {
    const channel = await store.dispatch('inboxes/createVoiceChannel', {
      name: `${t('INBOX_MGMT.ADD.VOICE.TITLE')} (${kazakhstanState.phoneNumber})`,
      voice: {
        phone_number: kazakhstanState.phoneNumber,
        provider: 'fonoster',
        provider_config: getKazakhstanProviderConfig(),
      },
    });

    router.replace({
      name: getInboxFlowRouteName(route, 'agents'),
      params: { page: 'new', inbox_id: channel.id },
    });
  } catch (error) {
    handleCreateError(error);
  }
}

async function createTwilioChannel() {
  const isFormValid = await twilioV$.value.$validate();
  if (!isFormValid) return;

  try {
    const channel = await store.dispatch('inboxes/createVoiceChannel', {
      name: `${t('INBOX_MGMT.ADD.VOICE.TITLE')} (${twilioState.phoneNumber})`,
      voice: {
        phone_number: twilioState.phoneNumber,
        provider: 'twilio',
        provider_config: {
          account_sid: twilioState.accountSid,
          auth_token: twilioState.authToken,
          api_key_sid: twilioState.apiKeySid,
          api_key_secret: twilioState.apiKeySecret,
        },
      },
    });

    router.replace({
      name: getInboxFlowRouteName(route, 'agents'),
      params: { page: 'new', inbox_id: channel.id },
    });
  } catch (error) {
    handleCreateError(error);
  }
}
</script>

<template>
  <div class="overflow-auto col-span-6 p-6 w-full h-full">
    <PageHeader
      :header-title="t('INBOX_MGMT.ADD.VOICE.TITLE')"
      :header-content="t('INBOX_MGMT.ADD.VOICE.DESC')"
    />

    <div v-if="showProviderSelection" class="mt-6">
      <div class="grid gap-6 md:grid-cols-2 max-w-4xl">
        <ChannelSelector
          v-for="provider in availableProviders"
          :key="provider.key"
          :title="provider.title"
          :description="provider.description"
          :icon="provider.icon"
          @click="selectProvider(provider.key)"
        />
      </div>
    </div>

    <div v-else class="mt-6 px-6 py-5 rounded-2xl border border-n-weak">
      <div
        class="flex flex-col gap-3 mb-6 md:flex-row md:items-start md:justify-between"
      >
        <div class="space-y-1">
          <h2 class="text-lg font-medium text-n-slate-12">
            {{ selectedProviderCard?.title }}
          </h2>
          <p class="text-sm text-n-slate-11">
            {{ selectedProviderCard?.description }}
          </p>
        </div>
        <button
          type="button"
          class="text-sm font-medium text-n-brand hover:opacity-80 text-left"
          @click="resetProviderSelection"
        >
          {{ t('INBOX_MGMT.ADD.VOICE.SELECT_PROVIDER.CHANGE_ACTION') }}
        </button>
      </div>

      <form
        v-if="selectedProvider === PROVIDER_TYPES.KAZAKHSTAN"
        class="flex flex-col gap-4 flex-wrap mx-0"
        @submit.prevent="createKazakhstanChannel"
      >
        <Input
          v-model="kazakhstanState.phoneNumber"
          :label="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.LABEL')"
          :placeholder="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.PLACEHOLDER')"
          :message="kazakhstanFormErrors.phoneNumber"
          :message-type="kazakhstanFormErrors.phoneNumber ? 'error' : 'info'"
          @blur="kazakhstanV$.phoneNumber?.$touch"
        />

        <Input
          v-model="kazakhstanState.numberRef"
          :label="t('INBOX_MGMT.ADD.VOICE.FONOSTER.NUMBER_REF.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.FONOSTER.NUMBER_REF.PLACEHOLDER')
          "
          :message="kazakhstanFormErrors.numberRef"
          :message-type="kazakhstanFormErrors.numberRef ? 'error' : 'info'"
          @blur="kazakhstanV$.numberRef?.$touch"
        />

        <Input
          v-model="kazakhstanState.appRef"
          :label="t('INBOX_MGMT.ADD.VOICE.FONOSTER.APP_REF.LABEL')"
          :placeholder="t('INBOX_MGMT.ADD.VOICE.FONOSTER.APP_REF.PLACEHOLDER')"
          :message="kazakhstanFormErrors.appRef"
          :message-type="kazakhstanFormErrors.appRef ? 'error' : 'info'"
          @blur="kazakhstanV$.appRef?.$touch"
        />

        <Input
          v-model="kazakhstanState.trunkRef"
          :label="t('INBOX_MGMT.ADD.VOICE.FONOSTER.TRUNK_REF.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.FONOSTER.TRUNK_REF.PLACEHOLDER')
          "
        />

        <div class="flex flex-col gap-2">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('INBOX_MGMT.ADD.VOICE.FONOSTER.ROUTING.LABEL') }}
          </label>
          <Select
            v-model="kazakhstanState.routingMode"
            class="w-full px-3 py-2"
            @blur="kazakhstanV$.routingMode?.$touch"
          >
            <option
              v-for="option in routingOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ option.label }}
            </option>
          </Select>
        </div>

        <Input
          v-if="kazakhstanState.routingMode === 'ai'"
          v-model="kazakhstanState.aiAppRef"
          :label="t('INBOX_MGMT.ADD.VOICE.FONOSTER.AI_APP_REF.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.FONOSTER.AI_APP_REF.PLACEHOLDER')
          "
          :message="kazakhstanFormErrors.aiAppRef"
          :message-type="kazakhstanFormErrors.aiAppRef ? 'error' : 'info'"
          @blur="kazakhstanV$.aiAppRef?.$touch"
        />

        <Input
          v-if="kazakhstanState.routingMode === 'operator'"
          v-model="kazakhstanState.operatorAgentAor"
          :label="t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_AOR.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.FONOSTER.OPERATOR_AGENT_AOR.PLACEHOLDER')
          "
          :message="kazakhstanFormErrors.operatorAgentAor"
          :message-type="
            kazakhstanFormErrors.operatorAgentAor ? 'error' : 'info'
          "
          @blur="kazakhstanV$.operatorAgentAor?.$touch"
        />

        <Input
          v-if="kazakhstanState.routingMode === 'reject'"
          v-model="kazakhstanState.fallbackMessage"
          :label="t('INBOX_MGMT.ADD.VOICE.FONOSTER.FALLBACK_MESSAGE.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.FONOSTER.FALLBACK_MESSAGE.PLACEHOLDER')
          "
        />

        <div>
          <NextButton
            :is-loading="uiFlags.isCreating"
            :disabled="isKazakhstanSubmitDisabled"
            :label="t('INBOX_MGMT.ADD.VOICE.SUBMIT_BUTTON')"
            type="submit"
          />
        </div>
      </form>

      <form
        v-else-if="selectedProvider === PROVIDER_TYPES.TWILIO"
        class="flex flex-col gap-4 flex-wrap mx-0"
        @submit.prevent="createTwilioChannel"
      >
        <Input
          v-model="twilioState.phoneNumber"
          :label="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.LABEL')"
          :placeholder="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.PLACEHOLDER')"
          :message="twilioFormErrors.phoneNumber"
          :message-type="twilioFormErrors.phoneNumber ? 'error' : 'info'"
          @blur="twilioV$.phoneNumber?.$touch"
        />

        <Input
          v-model="twilioState.accountSid"
          :label="t('INBOX_MGMT.ADD.VOICE.TWILIO.ACCOUNT_SID.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.TWILIO.ACCOUNT_SID.PLACEHOLDER')
          "
          :message="twilioFormErrors.accountSid"
          :message-type="twilioFormErrors.accountSid ? 'error' : 'info'"
          @blur="twilioV$.accountSid?.$touch"
        />

        <Input
          v-model="twilioState.authToken"
          type="password"
          :label="t('INBOX_MGMT.ADD.VOICE.TWILIO.AUTH_TOKEN.LABEL')"
          :placeholder="t('INBOX_MGMT.ADD.VOICE.TWILIO.AUTH_TOKEN.PLACEHOLDER')"
          :message="twilioFormErrors.authToken"
          :message-type="twilioFormErrors.authToken ? 'error' : 'info'"
          @blur="twilioV$.authToken?.$touch"
        />

        <Input
          v-model="twilioState.apiKeySid"
          :label="t('INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SID.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SID.PLACEHOLDER')
          "
          :message="twilioFormErrors.apiKeySid"
          :message-type="twilioFormErrors.apiKeySid ? 'error' : 'info'"
          @blur="twilioV$.apiKeySid?.$touch"
        />

        <Input
          v-model="twilioState.apiKeySecret"
          type="password"
          :label="t('INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SECRET.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SECRET.PLACEHOLDER')
          "
          :message="twilioFormErrors.apiKeySecret"
          :message-type="twilioFormErrors.apiKeySecret ? 'error' : 'info'"
          @blur="twilioV$.apiKeySecret?.$touch"
        />

        <div>
          <NextButton
            :is-loading="uiFlags.isCreating"
            :disabled="isTwilioSubmitDisabled"
            :label="t('INBOX_MGMT.ADD.VOICE.SUBMIT_BUTTON')"
            type="submit"
          />
        </div>
      </form>
    </div>
  </div>
</template>
