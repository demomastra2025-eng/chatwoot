<script setup>
import { reactive, computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { isPhoneE164 } from 'shared/helpers/Validators';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { getInboxFlowRouteName } from '../helpers/inboxFlowRoutes';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';

import PageHeader from '../../SettingsSubPageHeader.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import ChannelSelector from 'dashboard/components/ChannelSelector.vue';

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();

const PROVIDER_TYPES = {
  KAZAKHSTAN: 'kazakhstan',
  ASTERISK_ANALOG: 'asterisk_analog',
  SIPUNI: 'sipuni',
  BINOTEL: 'binotel',
  TWILIO: 'twilio',
};

const channelBadgePath = fileName =>
  `/integrations/channels/badges/${fileName}`;

const PROVIDER_BADGES = {
  [PROVIDER_TYPES.SIPUNI]: channelBadgePath('sipuni.png'),
  [PROVIDER_TYPES.BINOTEL]: channelBadgePath('binotel.png'),
  [PROVIDER_TYPES.ASTERISK_ANALOG]: channelBadgePath('Asterisk.png'),
};

const kazakhstanState = reactive({
  channelName: '',
  phoneNumber: '',
  providerKind: '',
  providerAccountNumber: '',
  ingressNumber: '',
  connectionHost: '',
  connectionPort: '5060',
  connectionTransport: 'udp',
  outboundDialFormat: 'kz_trunk',
});

const twilioState = reactive({
  phoneNumber: '',
  accountSid: '',
  authToken: '',
  apiKeySid: '',
  apiKeySecret: '',
});

const normalizeE164Input = value =>
  String(value || '').replace(/[\s().-]/g, '');

const isValidSipPort = value => {
  const port = String(value || '').trim();
  if (!/^\d+$/.test(port)) return false;

  const numericPort = Number(port);
  return (
    Number.isInteger(numericPort) && numericPort >= 1 && numericPort <= 65535
  );
};

const uiFlags = useMapGetter('inboxes/getUIFlags');
const agentList = useMapGetter('agents/getAgents');
const isCreatingVirtualPbx = ref(false);
const isVirtualPbxAdvancedVisible = ref(false);
const employeeProfiles = ref([]);

store.dispatch('agents/get');

const selectedProvider = computed(() => {
  return Object.values(PROVIDER_TYPES).includes(route.query.provider)
    ? route.query.provider
    : '';
});

const isSipuniProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.SIPUNI
);
const isBinotelProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.BINOTEL
);
const isAsteriskAnalogSelectedProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.ASTERISK_ANALOG
);
const isDirectProviderOwnedSipProvider = computed(
  () =>
    isSipuniProvider.value ||
    isBinotelProvider.value ||
    isAsteriskAnalogSelectedProvider.value
);
const selectedVirtualPbxProviderKind = computed(() => {
  if (isSipuniProvider.value) return 'sipuni';
  if (isBinotelProvider.value) return 'binotel';
  if (isAsteriskAnalogSelectedProvider.value) return 'asterisk_analog';

  return kazakhstanState.providerKind;
});
const isAsteriskAnalogProvider = computed(
  () => selectedVirtualPbxProviderKind.value === 'asterisk_analog'
);
const showProviderSelection = computed(() => !selectedProvider.value);

const selectedEmployeeIds = computed(() =>
  employeeProfiles.value.map(profile => profile.userId)
);

const selectedEmployeeNames = computed(() =>
  employeeProfiles.value.map(profile => profile.name)
);

const employeeMenuItems = computed(() =>
  (agentList.value || [])
    .filter(agent => !selectedEmployeeIds.value.includes(Number(agent.id)))
    .map(agent => ({
      label:
        agent.name || agent.available_name || agent.email || `#${agent.id}`,
      value: Number(agent.id),
      action: 'select',
      thumbnail: {
        name: agent.name,
        src: agent.thumbnail || agent.avatar_url || '',
      },
    }))
);

const availableProviders = computed(() => [
  {
    key: PROVIDER_TYPES.KAZAKHSTAN,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KAZAKHSTAN'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KAZAKHSTAN_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
  },
  {
    key: PROVIDER_TYPES.SIPUNI,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.SIPUNI'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.SIPUNI_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.SIPUNI],
  },
  {
    key: PROVIDER_TYPES.ASTERISK_ANALOG,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.ASTERISK_ANALOG'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.ASTERISK_ANALOG_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.ASTERISK_ANALOG],
  },
  {
    key: PROVIDER_TYPES.BINOTEL,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.BINOTEL'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.BINOTEL_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.BINOTEL],
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
  channelName: { required },
  phoneNumber: { required, isPhoneE164 },
  providerKind: isDirectProviderOwnedSipProvider.value ? {} : { required },
  connectionHost: { required },
  connectionPort: { required, isValidSipPort },
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

const virtualPbxProviderOptions = computed(() => [
  {
    value: 'sipuni',
    label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.SIPUNI'),
  },
  {
    value: 'binotel',
    label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.BINOTEL'),
  },
  {
    value: 'asterisk_analog',
    label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.ASTERISK_ANALOG'),
  },
]);

const transportOptions = ['udp', 'tcp', 'tls'];

const outboundDialFormatOptions = computed(() => [
  {
    value: 'kz_trunk',
    label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.KZ_TRUNK'),
  },
  {
    value: 'strip_plus',
    label: t(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.STRIP_PLUS'
    ),
  },
  {
    value: 'e164',
    label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.E164'),
  },
]);

const kazakhstanFormErrors = computed(() => ({
  channelName: kazakhstanV$.value.channelName?.$error
    ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CHANNEL_NAME.REQUIRED')
    : '',
  phoneNumber: kazakhstanV$.value.phoneNumber?.$error
    ? t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.ERROR')
    : '',
  providerAccountNumber: kazakhstanV$.value.providerAccountNumber?.$error
    ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_ACCOUNT_NUMBER.REQUIRED')
    : '',
  ingressNumber: kazakhstanV$.value.ingressNumber?.$error
    ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INGRESS_NUMBER.REQUIRED')
    : '',
  connectionHost: kazakhstanV$.value.connectionHost?.$error
    ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.REQUIRED')
    : '',
  connectionPort: kazakhstanV$.value.connectionPort?.$error
    ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.INVALID')
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
  if (provider === PROVIDER_TYPES.SIPUNI) {
    kazakhstanState.providerKind = 'sipuni';
  }
  if (provider === PROVIDER_TYPES.BINOTEL) {
    kazakhstanState.providerKind = 'binotel';
  }
  if (provider === PROVIDER_TYPES.ASTERISK_ANALOG) {
    kazakhstanState.providerKind = 'asterisk_analog';
  }

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

function handleEmployeeAdd({ value }) {
  const userId = Number(value);
  if (!userId || selectedEmployeeIds.value.includes(userId)) return;

  const agent = (agentList.value || []).find(
    item => Number(item.id) === userId
  );
  employeeProfiles.value.push({
    userId,
    name: agent?.name || agent?.available_name || agent?.email || `#${userId}`,
    internalExtension: '',
    sipUsername: '',
    sipPassword: '',
    enabled: true,
  });
}

function handleEmployeeRemove(index) {
  employeeProfiles.value.splice(index, 1);
}

function employeeProfilesPayload() {
  return employeeProfiles.value.map(profile => {
    const payload = {
      profile_kind: 'human_operator',
      user_id: profile.userId,
      internal_extension: profile.internalExtension.trim(),
      enabled: profile.enabled !== false,
    };
    const sipUsername = profile.sipUsername.trim();
    const sipPassword = profile.sipPassword.trim();
    if (sipUsername) payload.sip_username = sipUsername;
    if (sipPassword) payload.sip_password = sipPassword;
    return payload;
  });
}

function validateEmployeeProfiles() {
  const missingExtension = employeeProfiles.value.some(
    profile => !profile.internalExtension.trim()
  );
  if (missingExtension) {
    useAlert(t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.REQUIRED'));
    return false;
  }

  const invalidSipPair = employeeProfiles.value.some(profile => {
    const hasUsername = !!profile.sipUsername.trim();
    const hasPassword = !!profile.sipPassword.trim();
    return hasUsername !== hasPassword;
  });
  if (invalidSipPair) {
    useAlert(
      t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SIP_PAIR_REQUIRED')
    );
    return false;
  }

  return true;
}

function getVirtualPbxPayload() {
  const providerKind = selectedVirtualPbxProviderKind.value;
  const displayPhoneNumber = kazakhstanState.phoneNumber.trim();
  const ingressNumber =
    kazakhstanState.ingressNumber.trim() || displayPhoneNumber;
  const providerAccountNumber =
    kazakhstanState.providerAccountNumber.trim() || ingressNumber;
  const connection = {
    host: kazakhstanState.connectionHost.trim(),
  };
  const routing = {
    mode: 'operator',
    fallback_mode: 'reject',
    operator_distribution_mode: 'broadcast',
  };

  if (isAsteriskAnalogProvider.value) {
    connection.port = kazakhstanState.connectionPort.trim();
    connection.transport = kazakhstanState.connectionTransport;
  }

  const payload = {
    provider_kind: providerKind,
    channel_name: kazakhstanState.channelName.trim(),
    display_phone_number: displayPhoneNumber,
    provider_account_number: providerAccountNumber,
    ingress_number: ingressNumber,
    connection,
    routing,
    metadata: {
      source: 'virtual_pbx_ui',
    },
  };

  if (isAsteriskAnalogProvider.value) {
    payload.metadata.outbound_dial_format = kazakhstanState.outboundDialFormat;
  }

  if (employeeProfiles.value.length) {
    payload.profiles = employeeProfilesPayload();
  }

  return payload;
}

function provisioningErrorMessage(response) {
  const errors = response?.payload?.errors || response?.errors || [];
  if (errors.length) {
    return errors.map(error => error.message || error.code).join(', ');
  }

  return '';
}

function handleCreateError(error) {
  useAlert(
    error.response?.data?.message || t('INBOX_MGMT.ADD.VOICE.API.ERROR_MESSAGE')
  );
}

function agentsRouteParams(inboxId) {
  return {
    accountId: route.params.accountId,
    inbox_id: inboxId,
  };
}

async function createKazakhstanChannel() {
  kazakhstanState.phoneNumber = normalizeE164Input(kazakhstanState.phoneNumber);

  const isFormValid = await kazakhstanV$.value.$validate();
  if (!isFormValid || !validateEmployeeProfiles()) return;

  isCreatingVirtualPbx.value = true;
  try {
    const response = await VoiceAPI.createVirtualPbxChannel(
      getVirtualPbxPayload(),
      { dryRun: false, remoteCommit: false }
    );
    const provisioningError = provisioningErrorMessage(response);
    if (provisioningError) {
      useAlert(provisioningError);
      return;
    }

    const inboxId =
      response?.payload?.ui_config?.inbox_id ||
      response?.payload?.config?.inbox_id;
    if (!inboxId) {
      useAlert(t('INBOX_MGMT.ADD.VOICE.API.ERROR_MESSAGE'));
      return;
    }

    useAlert(t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CREATE_SUCCESS'));
    const nextStep = employeeProfiles.value.length ? 'finish' : 'agents';
    router.replace({
      name: getInboxFlowRouteName(route, nextStep),
      params: agentsRouteParams(inboxId),
      ...(nextStep === 'agents'
        ? { query: { provider: selectedVirtualPbxProviderKind.value } }
        : {}),
    });
  } catch (error) {
    handleCreateError(error);
  } finally {
    isCreatingVirtualPbx.value = false;
  }
}

async function createTwilioChannel() {
  const isFormValid = await twilioV$.value.$validate();
  if (!isFormValid) return;

  try {
    const channel = await store.dispatch('inboxes/createVoiceChannel', {
      name: twilioState.phoneNumber,
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
      params: agentsRouteParams(channel.id),
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
      <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3 max-w-5xl">
        <ChannelSelector
          v-for="provider in availableProviders"
          :key="provider.key"
          :title="provider.title"
          :description="provider.description"
          :icon="provider.icon"
          :image-url="provider.imageUrl"
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
        v-if="
          selectedProvider === PROVIDER_TYPES.KAZAKHSTAN ||
          selectedProvider === PROVIDER_TYPES.SIPUNI ||
          selectedProvider === PROVIDER_TYPES.ASTERISK_ANALOG ||
          selectedProvider === PROVIDER_TYPES.BINOTEL
        "
        class="flex flex-col gap-4 flex-wrap mx-0"
        @submit.prevent="createKazakhstanChannel"
      >
        <Input
          v-model="kazakhstanState.channelName"
          :label="t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CHANNEL_NAME.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CHANNEL_NAME.PLACEHOLDER')
          "
          :message="kazakhstanFormErrors.channelName"
          :message-type="kazakhstanFormErrors.channelName ? 'error' : 'info'"
          @blur="kazakhstanV$.channelName?.$touch"
        />

        <Input
          v-model="kazakhstanState.phoneNumber"
          :label="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.LABEL')"
          :placeholder="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.PLACEHOLDER')"
          :message="kazakhstanFormErrors.phoneNumber"
          :message-type="kazakhstanFormErrors.phoneNumber ? 'error' : 'info'"
          @blur="kazakhstanV$.phoneNumber?.$touch"
        />

        <div
          v-if="!isDirectProviderOwnedSipProvider"
          class="flex flex-col gap-2"
        >
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.LABEL') }}
          </label>
          <Select
            v-model="kazakhstanState.providerKind"
            class="w-full px-3 py-2"
            @blur="kazakhstanV$.providerKind?.$touch"
          >
            <option value="" disabled>
              {{
                t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.PROVIDER_KIND.PLACEHOLDER')
              }}
            </option>
            <option
              v-for="option in virtualPbxProviderOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ option.label }}
            </option>
          </Select>
        </div>

        <button
          v-if="isAsteriskAnalogProvider"
          type="button"
          class="text-sm font-medium text-n-brand hover:opacity-80 text-left"
          @click="isVirtualPbxAdvancedVisible = !isVirtualPbxAdvancedVisible"
        >
          {{
            isVirtualPbxAdvancedVisible
              ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ADVANCED_FIELDS.HIDE')
              : t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ADVANCED_FIELDS.SHOW')
          }}
        </button>

        <Input
          v-model="kazakhstanState.connectionHost"
          :label="t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.LABEL')"
          :placeholder="
            t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_HOST.PLACEHOLDER')
          "
          :message="kazakhstanFormErrors.connectionHost"
          :message-type="kazakhstanFormErrors.connectionHost ? 'error' : 'info'"
          @blur="kazakhstanV$.connectionHost?.$touch"
        />

        <div
          v-if="isVirtualPbxAdvancedVisible && isAsteriskAnalogProvider"
          class="grid grid-cols-1 gap-4 md:grid-cols-3"
        >
          <Input
            v-model="kazakhstanState.connectionPort"
            type="number"
            min="1"
            max="65535"
            :label="t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.LABEL')"
            :placeholder="
              t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CONNECTION_PORT.PLACEHOLDER')
            "
            :message="kazakhstanFormErrors.connectionPort"
            :message-type="
              kazakhstanFormErrors.connectionPort ? 'error' : 'info'
            "
            @blur="kazakhstanV$.connectionPort?.$touch"
          />
          <div class="flex flex-col gap-2">
            <label class="text-sm font-medium text-n-slate-12">
              {{ t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.TRANSPORT.LABEL') }}
            </label>
            <Select
              v-model="kazakhstanState.connectionTransport"
              class="w-full px-3 py-2"
            >
              <option
                v-for="option in transportOptions"
                :key="option"
                :value="option"
              >
                {{ option.toUpperCase() }}
              </option>
            </Select>
          </div>
          <div class="flex flex-col gap-2">
            <label class="text-sm font-medium text-n-slate-12">
              {{
                t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.LABEL')
              }}
            </label>
            <Select
              v-model="kazakhstanState.outboundDialFormat"
              class="w-full px-3 py-2"
            >
              <option
                v-for="option in outboundDialFormatOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ option.label }}
              </option>
            </Select>
          </div>
        </div>

        <div class="rounded-xl border border-n-weak p-4 space-y-4">
          <div class="space-y-1">
            <h3 class="text-sm font-medium text-n-slate-12">
              {{
                t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.TITLE')
              }}
            </h3>
            <p class="text-sm text-n-slate-11">
              {{
                t(
                  'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.CREATE_HINT'
                )
              }}
            </p>
          </div>

          <div
            class="rounded-xl outline outline-1 -outline-offset-1 outline-n-weak hover:outline-n-strong px-2 py-2"
          >
            <TagInput
              :model-value="selectedEmployeeNames"
              :placeholder="
                t(
                  'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.SELECT_PLACEHOLDER'
                )
              "
              :menu-items="employeeMenuItems"
              show-dropdown
              skip-label-dedup
              @add="handleEmployeeAdd"
              @remove="handleEmployeeRemove"
            />
          </div>

          <div v-if="employeeProfiles.length" class="flex flex-col gap-3">
            <div
              v-for="profile in employeeProfiles"
              :key="profile.userId"
              class="grid grid-cols-1 gap-3 rounded-lg border border-n-weak p-3 md:grid-cols-4"
            >
              <div class="flex flex-col gap-1 text-sm text-n-slate-12">
                <span class="font-medium">
                  {{
                    t(
                      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.EMPLOYEE_LABEL'
                    )
                  }}
                </span>
                <span class="min-h-[38px] rounded-lg bg-n-slate-2 px-3 py-2">
                  {{ profile.name }}
                </span>
              </div>

              <Input
                v-model="profile.internalExtension"
                :label="
                  t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.LABEL')
                "
                :placeholder="
                  t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.INTERNAL_EXTENSION.PLACEHOLDER'
                  )
                "
              />

              <Input
                v-model="profile.sipUsername"
                :label="
                  t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.LABEL'
                  )
                "
                :placeholder="
                  t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_USERNAME.PLACEHOLDER'
                  )
                "
              />

              <Input
                v-model="profile.sipPassword"
                type="password"
                autocomplete="new-password"
                :label="
                  t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.LABEL'
                  )
                "
                :placeholder="
                  t(
                    'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_SIP_PASSWORD.PLACEHOLDER'
                  )
                "
              />
            </div>
          </div>
        </div>

        <div>
          <NextButton
            :is-loading="isCreatingVirtualPbx || uiFlags.isCreating"
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
