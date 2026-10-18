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
import {
  virtualPbxErrorsText,
  virtualPbxRequestErrorText,
} from 'dashboard/api/channel/voice/virtualPbxErrors';

import PageHeader from '../../SettingsSubPageHeader.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ChannelSelector from 'dashboard/components/ChannelSelector.vue';

const { t, te } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();

const PROVIDER_TYPES = {
  WAZO: 'wazo',
  ALTEL: 'altel',
  TELE2: 'tele2',
  KAZAKHTELECOM: 'kazakhtelecom',
  KCELL: 'kcell',
  ASTERISK_ANALOG: 'asterisk_analog',
  SIPUNI: 'sipuni',
  BINOTEL: 'binotel',
  BEELINE: 'beeline',
  TWILIO: 'twilio',
};

const WAZO_CARRIER_PROVIDERS = [
  PROVIDER_TYPES.ALTEL,
  PROVIDER_TYPES.TELE2,
  PROVIDER_TYPES.KAZAKHTELECOM,
  PROVIDER_TYPES.KCELL,
];

const CARRIER_PRESETS = {
  altel: { domain: 'astpbx.tele2.kz', host: '91.185.24.71', maxChannels: 10 },
  tele2: { domain: 'astpbx.tele2.kz', host: '91.185.24.71', maxChannels: 10 },
  kazakhtelecom: {
    domain: 'sip.telecom.kz',
    host: 'sip.telecom.kz',
    maxChannels: 10,
  },
  kcell: { domain: 'sip.kcell.kz', host: 'sip.kcell.kz', maxChannels: 10 },
  beeline_trunk: {
    domain: 'cloudpbx.beeline.kz',
    host: '46.227.186.231',
    maxChannels: 10,
  },
  custom: { domain: '', host: '', maxChannels: 10 },
};

const KNOWN_CARRIER_PRESETS = [
  'altel',
  'tele2',
  'kazakhtelecom',
  'kcell',
  'beeline_trunk',
];

const DEFAULT_WAZO_SIP_HOST = '188.241.217.162';
const defaultWazoSipHost = () =>
  window.chatwootConfig?.wazoSipHost || DEFAULT_WAZO_SIP_HOST;

const normalizedRouteProvider = provider =>
  provider === 'kazakhstan' ? PROVIDER_TYPES.WAZO : provider;

const initialCarrierKind = () => {
  const provider = normalizedRouteProvider(route.query.provider);
  if (WAZO_CARRIER_PROVIDERS.includes(provider)) return provider;
  if (provider === PROVIDER_TYPES.WAZO) return 'custom';
  return '';
};

const channelBadgePath = fileName =>
  `/integrations/channels/badges/${fileName}`;

const defaultProviderConnectionHost = provider => {
  const normalized = normalizedRouteProvider(provider);
  if (normalized === PROVIDER_TYPES.BEELINE) return 'cloudpbx.beeline.kz';
  if (normalized === PROVIDER_TYPES.SIPUNI) return 'sipuni.com';
  if (normalized === PROVIDER_TYPES.BINOTEL) return 'sip.binotel.com';
  if (
    normalized === PROVIDER_TYPES.WAZO ||
    normalized === PROVIDER_TYPES.ASTERISK_ANALOG ||
    WAZO_CARRIER_PROVIDERS.includes(normalized)
  ) {
    return defaultWazoSipHost();
  }
  return defaultWazoSipHost();
};

const initialConnectionHost = () =>
  defaultProviderConnectionHost(route.query.provider);

// Beeline Cloud PBX connects outbound calls dialed as +7XXXXXXXXXX.
const BEELINE_OUTBOUND_DIAL_FORMAT = 'e164_plus';
const initialOutboundDialFormat = () =>
  route.query.provider === PROVIDER_TYPES.BEELINE
    ? BEELINE_OUTBOUND_DIAL_FORMAT
    : 'kz_trunk';

const PROVIDER_BADGES = {
  [PROVIDER_TYPES.WAZO]: channelBadgePath('custom-sip.svg'),
  [PROVIDER_TYPES.ALTEL]: channelBadgePath('altel.svg'),
  [PROVIDER_TYPES.TELE2]: channelBadgePath('tele2.svg'),
  [PROVIDER_TYPES.KAZAKHTELECOM]: channelBadgePath('kazakhtelecom.svg'),
  [PROVIDER_TYPES.KCELL]: channelBadgePath('kcell.svg'),
  [PROVIDER_TYPES.SIPUNI]: channelBadgePath('sipuni.png'),
  [PROVIDER_TYPES.BINOTEL]: channelBadgePath('binotel.png'),
  [PROVIDER_TYPES.ASTERISK_ANALOG]: channelBadgePath('Asterisk.png'),
  [PROVIDER_TYPES.BEELINE]: channelBadgePath('beeline-sign-logo.png'),
};

const kazakhstanState = reactive({
  channelName: '',
  phoneNumber: '',
  providerKind:
    normalizedRouteProvider(route.query.provider) === PROVIDER_TYPES.WAZO ||
    WAZO_CARRIER_PROVIDERS.includes(route.query.provider)
      ? PROVIDER_TYPES.WAZO
      : normalizedRouteProvider(route.query.provider) || '',
  carrierKind: initialCarrierKind(),
  maxChannels: CARRIER_PRESETS[initialCarrierKind()]?.maxChannels || 10,
  trunkUsername: '',
  trunkPassword: '',
  trunkDomain:
    CARRIER_PRESETS[initialCarrierKind()]?.domain ||
    (normalizedRouteProvider(route.query.provider) === PROVIDER_TYPES.WAZO
      ? defaultWazoSipHost()
      : ''),
  trunkHost:
    CARRIER_PRESETS[initialCarrierKind()]?.host ||
    (normalizedRouteProvider(route.query.provider) === PROVIDER_TYPES.WAZO
      ? defaultWazoSipHost()
      : ''),
  providerAccountNumber: '',
  ingressNumber: '',
  connectionHost: initialConnectionHost(),
  connectionPort: '5060',
  connectionTransport: 'udp',
  connectionSipDomain:
    route.query.provider === PROVIDER_TYPES.BEELINE
      ? 'cloudpbx.beeline.kz'
      : '',
  connectionOutboundProxy:
    route.query.provider === PROVIDER_TYPES.BEELINE
      ? '46.227.186.231:6050'
      : '',
  outboundDialFormat: initialOutboundDialFormat(),
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

const uiFlags = useMapGetter('inboxes/getUIFlags');
const isCreatingVirtualPbx = ref(false);

const selectedProvider = computed(() => {
  const provider = normalizedRouteProvider(route.query.provider);
  return Object.values(PROVIDER_TYPES).includes(provider) ? provider : '';
});

const isSipuniProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.SIPUNI
);
const isBinotelProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.BINOTEL
);
const isBeelineProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.BEELINE
);
const isAsteriskAnalogSelectedProvider = computed(
  () => selectedProvider.value === PROVIDER_TYPES.ASTERISK_ANALOG
);
const isWazoSelectedProvider = computed(
  () =>
    selectedProvider.value === PROVIDER_TYPES.WAZO ||
    WAZO_CARRIER_PROVIDERS.includes(selectedProvider.value)
);
const isDirectProviderOwnedSipProvider = computed(
  () =>
    isSipuniProvider.value ||
    isBinotelProvider.value ||
    isBeelineProvider.value ||
    isAsteriskAnalogSelectedProvider.value ||
    isWazoSelectedProvider.value
);
const selectedVirtualPbxProviderKind = computed(() => {
  if (isWazoSelectedProvider.value) return PROVIDER_TYPES.WAZO;
  if (isSipuniProvider.value) return 'sipuni';
  if (isBinotelProvider.value) return 'binotel';
  if (isBeelineProvider.value) return 'beeline';
  if (isAsteriskAnalogSelectedProvider.value) return 'asterisk_analog';

  return kazakhstanState.providerKind;
});
const isAsteriskAnalogProvider = computed(
  () => selectedVirtualPbxProviderKind.value === 'asterisk_analog'
);
const isWazoProvider = computed(
  () => selectedVirtualPbxProviderKind.value === PROVIDER_TYPES.WAZO
);
const isCarrierLocked = computed(() =>
  WAZO_CARRIER_PROVIDERS.includes(selectedProvider.value)
);
const isKnownCarrierPreset = computed(() =>
  KNOWN_CARRIER_PRESETS.includes(kazakhstanState.carrierKind)
);
const showProviderSelection = computed(() => !selectedProvider.value);

const availableProviders = computed(() => [
  {
    key: PROVIDER_TYPES.ALTEL,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.ALTEL'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.ALTEL_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.ALTEL],
  },
  {
    key: PROVIDER_TYPES.TELE2,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.TELE2'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.TELE2_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.TELE2],
  },
  {
    key: PROVIDER_TYPES.KAZAKHTELECOM,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KAZAKHTELECOM'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KAZAKHTELECOM_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.KAZAKHTELECOM],
  },
  {
    key: PROVIDER_TYPES.KCELL,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KCELL'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.KCELL_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.KCELL],
  },
  {
    key: PROVIDER_TYPES.SIPUNI,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.SIPUNI'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.SIPUNI_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.SIPUNI],
  },
  {
    key: PROVIDER_TYPES.BINOTEL,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.BINOTEL'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.BINOTEL_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.BINOTEL],
  },
  {
    key: PROVIDER_TYPES.BEELINE,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.BEELINE'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.BEELINE_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.BEELINE],
  },
  {
    key: PROVIDER_TYPES.ASTERISK_ANALOG,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.ASTERISK_ANALOG'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.ASTERISK_ANALOG_DESC'),
    icon: 'i-ph-phone-call-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.ASTERISK_ANALOG],
  },
  {
    key: PROVIDER_TYPES.WAZO,
    title: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.WAZO'),
    description: t('INBOX_MGMT.ADD.VOICE.PROVIDERS.WAZO_DESC'),
    icon: 'i-ri-phone-fill channel-icon-voice',
    imageUrl: PROVIDER_BADGES[PROVIDER_TYPES.WAZO],
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

const outboundDialFormatOptions = computed(() => {
  const kzTrunk = {
    value: 'kz_trunk',
    label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.KZ_TRUNK'),
  };
  const stripPlus = {
    value: 'strip_plus',
    label: t(
      'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.STRIP_PLUS'
    ),
  };

  if (isBeelineProvider.value) {
    return [
      {
        value: BEELINE_OUTBOUND_DIAL_FORMAT,
        label: t(
          'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.E164_PLUS'
        ),
      },
      kzTrunk,
      stripPlus,
    ];
  }

  return [
    kzTrunk,
    stripPlus,
    {
      value: 'e164',
      label: t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.OUTBOUND_DIAL_FORMAT.E164'),
    },
  ];
});

defineExpose({
  kazakhstanState,
  isWazoProvider,
  isCarrierLocked,
  isKnownCarrierPreset,
  outboundDialFormatOptions,
});

const kazakhstanFormErrors = computed(() => ({
  channelName: kazakhstanV$.value.channelName?.$error
    ? t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CHANNEL_NAME.REQUIRED')
    : '',
  phoneNumber: kazakhstanV$.value.phoneNumber?.$error
    ? t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.ERROR')
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

function onCarrierKindChange() {
  const preset = CARRIER_PRESETS[kazakhstanState.carrierKind];
  if (!preset) return;
  kazakhstanState.trunkDomain = preset.domain || '';
  kazakhstanState.trunkHost = preset.host || '';
  kazakhstanState.maxChannels = preset.maxChannels || 10;
}

function selectProvider(provider) {
  kazakhstanState.connectionHost = defaultProviderConnectionHost(provider);
  kazakhstanState.connectionPort = '5060';
  kazakhstanState.connectionTransport = 'udp';
  kazakhstanState.connectionOutboundProxy = '';
  kazakhstanState.connectionSipDomain = '';
  kazakhstanState.outboundDialFormat = 'kz_trunk';
  kazakhstanState.maxChannels = 10;

  if (
    provider === PROVIDER_TYPES.WAZO ||
    WAZO_CARRIER_PROVIDERS.includes(provider)
  ) {
    kazakhstanState.providerKind = PROVIDER_TYPES.WAZO;
    if (WAZO_CARRIER_PROVIDERS.includes(provider)) {
      kazakhstanState.carrierKind = provider;
      onCarrierKindChange();
    } else {
      kazakhstanState.carrierKind = 'custom';
      kazakhstanState.trunkDomain = defaultWazoSipHost();
      kazakhstanState.trunkHost = defaultWazoSipHost();
    }
  }
  if (provider === PROVIDER_TYPES.SIPUNI) {
    kazakhstanState.providerKind = 'sipuni';
  }
  if (provider === PROVIDER_TYPES.BINOTEL) {
    kazakhstanState.providerKind = 'binotel';
  }
  if (provider === PROVIDER_TYPES.ASTERISK_ANALOG) {
    kazakhstanState.providerKind = 'asterisk_analog';
  }
  if (provider === PROVIDER_TYPES.BEELINE) {
    kazakhstanState.providerKind = 'beeline';
    kazakhstanState.connectionSipDomain = 'cloudpbx.beeline.kz';
    kazakhstanState.connectionOutboundProxy = '46.227.186.231:6050';
    kazakhstanState.outboundDialFormat = BEELINE_OUTBOUND_DIAL_FORMAT;
  }

  router.push({
    name: route.name,
    params: route.params,
    query: { provider },
  });
}

function getVirtualPbxPayload() {
  const providerKind = selectedVirtualPbxProviderKind.value;
  const displayPhoneNumber = kazakhstanState.phoneNumber.trim();
  const ingressNumber =
    kazakhstanState.ingressNumber.trim() || displayPhoneNumber;
  const providerAccountNumber =
    kazakhstanState.providerAccountNumber.trim() || ingressNumber;
  const resolvedHost =
    kazakhstanState.connectionHost.trim() ||
    defaultProviderConnectionHost(selectedProvider.value);
  const connection = {
    host: resolvedHost,
  };
  const routing = {
    mode: 'operator',
    fallback_mode: 'reject',
    operator_distribution_mode: 'broadcast',
  };

  if (isAsteriskAnalogProvider.value || isWazoProvider.value) {
    connection.port = kazakhstanState.connectionPort.trim() || '5060';
    connection.transport = kazakhstanState.connectionTransport || 'udp';
  }
  if (isBeelineProvider.value) {
    connection.port = '5060';
    connection.transport = 'udp';
    connection.sip_domain =
      kazakhstanState.connectionSipDomain.trim() || 'cloudpbx.beeline.kz';
    connection.outbound_proxy =
      kazakhstanState.connectionOutboundProxy.trim() || '46.227.186.231:6050';
    connection.codec = 'pcma';
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
      pbx_platform: isWazoProvider.value ? 'wazo' : undefined,
    },
  };

  if (
    isAsteriskAnalogProvider.value ||
    isWazoProvider.value ||
    isBeelineProvider.value
  ) {
    payload.metadata.outbound_dial_format = kazakhstanState.outboundDialFormat;
  }

  if (isWazoProvider.value && kazakhstanState.carrierKind) {
    connection.carrier_kind = kazakhstanState.carrierKind;
    connection.max_channels = Number(kazakhstanState.maxChannels) || 10;
    if (kazakhstanState.trunkUsername.trim()) {
      connection.trunk_username = kazakhstanState.trunkUsername.trim();
    }
    if (kazakhstanState.trunkPassword) {
      connection.trunk_password = kazakhstanState.trunkPassword;
    }
    if (kazakhstanState.trunkDomain.trim()) {
      connection.trunk_domain = kazakhstanState.trunkDomain.trim();
    }
    if (kazakhstanState.trunkHost.trim()) {
      connection.trunk_host = kazakhstanState.trunkHost.trim();
    }
    payload.metadata.carrier_kind = kazakhstanState.carrierKind;
  } else if (kazakhstanState.trunkUsername.trim()) {
    connection.trunk_username = kazakhstanState.trunkUsername.trim();
    if (kazakhstanState.trunkPassword) {
      connection.trunk_password = kazakhstanState.trunkPassword;
    }
  }

  return payload;
}

function provisioningErrorMessage(response) {
  const errors = response?.payload?.errors || response?.errors || [];
  return virtualPbxErrorsText(errors, { t, te });
}

function handleCreateError(error) {
  useAlert(
    virtualPbxRequestErrorText(
      error,
      { t, te },
      t('INBOX_MGMT.ADD.VOICE.API.ERROR_MESSAGE')
    )
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
  if (!isFormValid) return;

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
    router.replace({
      name: getInboxFlowRouteName(route, 'agents'),
      params: agentsRouteParams(inboxId),
      query: { provider: selectedVirtualPbxProviderKind.value },
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
          apiKeySecret: twilioState.apiKeySecret,
        },
      },
    });

    router.replace({
      name: getInboxFlowRouteName(route, 'finish'),
      params: agentsRouteParams(channel.id),
      query: { provider: 'twilio' },
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

    <div
      v-else
      class="mt-6 px-6 py-5 rounded-xl outline outline-1 -outline-offset-1 outline-n-weak"
    >
      <div class="flex items-start gap-3 mb-6">
        <img
          v-if="selectedProviderCard?.imageUrl"
          :src="selectedProviderCard.imageUrl"
          alt=""
          class="size-10 shrink-0 rounded-lg object-contain"
        />
        <div class="space-y-1">
          <h2 class="text-lg font-medium text-n-slate-12">
            {{ selectedProviderCard?.title }}
          </h2>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ selectedProviderCard?.description }}
          </p>
        </div>
      </div>

      <form
        v-if="isDirectProviderOwnedSipProvider"
        class="flex flex-col gap-4 flex-wrap mx-0"
        @submit.prevent="createKazakhstanChannel"
      >
        <Input
          v-model="kazakhstanState.channelName"
          data-testid="voice-channel-name-input"
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
          data-testid="voice-phone-number-input"
          :label="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.LABEL')"
          :placeholder="t('INBOX_MGMT.ADD.VOICE.PHONE_NUMBER.PLACEHOLDER')"
          :message="kazakhstanFormErrors.phoneNumber"
          :message-type="kazakhstanFormErrors.phoneNumber ? 'error' : 'info'"
          @blur="kazakhstanV$.phoneNumber?.$touch"
        />

        <Input
          v-model="kazakhstanState.trunkUsername"
          data-testid="voice-sip-username-input"
          :label="
            t(
              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_USERNAME_LABEL'
            )
          "
          :placeholder="
            t(
              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_USERNAME_PLACEHOLDER'
            )
          "
        />

        <Input
          v-model="kazakhstanState.trunkPassword"
          type="password"
          data-testid="voice-sip-password-input"
          :label="
            t(
              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_PASSWORD_LABEL'
            )
          "
          :placeholder="
            t(
              'INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.CARRIER_SETTINGS.TRUNK_PASSWORD_PLACEHOLDER'
            )
          "
        />

        <p class="mb-0 text-sm text-n-slate-11">
          {{
            t('INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.EMPLOYEE_PROFILES.CREATE_HINT')
          }}
        </p>

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
