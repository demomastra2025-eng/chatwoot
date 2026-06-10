<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => ({}),
  },
});

const { t } = useI18n();

const readinessPayload = ref(null);
const virtualPbxPayload = ref(null);
const isLoading = ref(false);
const loadError = ref('');
const partialLoadError = ref('');

const isFonosterVoiceInbox = computed(() => {
  return (
    props.inbox?.channel_type === 'Channel::Voice' &&
    props.inbox?.provider === 'fonoster'
  );
});

const bridge = computed(() => readinessPayload.value?.bridge || null);
const account = computed(() => readinessPayload.value?.account || null);
const inboxReadiness = computed(() => {
  const inboxes = readinessPayload.value?.inboxes || [];
  return inboxes.find(item => item.id === props.inbox?.id) || null;
});
const virtualPbxConfig = computed(
  () => virtualPbxPayload.value?.config || null
);
const virtualPbxWarnings = computed(() => {
  const payloadWarnings = virtualPbxPayload.value?.warnings || [];
  return payloadWarnings.length
    ? payloadWarnings
    : virtualPbxConfig.value?.warnings || [];
});
const virtualPbxPhoneNumbers = computed(() => {
  return virtualPbxConfig.value?.phone_numbers || {};
});
const virtualPbxResources = computed(() => {
  return virtualPbxConfig.value?.resources || {};
});
const virtualPbxProfiles = computed(() => {
  return virtualPbxConfig.value?.profiles || [];
});

const accountWarnings = computed(() => {
  const warnings = readinessPayload.value?.warnings || [];
  return warnings.filter(
    warning =>
      !['inboxes_not_ready', 'no_fonoster_inboxes'].includes(warning.code)
  );
});

const warnings = computed(() => {
  return [
    ...accountWarnings.value,
    ...(inboxReadiness.value?.warnings || []),
    ...virtualPbxWarnings.value,
  ];
});

const isReady = computed(() => {
  const virtualPbxReady = virtualPbxConfig.value?.ready ?? true;
  return Boolean(
    bridge.value?.healthy && inboxReadiness.value?.ready && virtualPbxReady
  );
});

const readinessStatusLabel = computed(() => {
  return isReady.value
    ? t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.READY')
    : t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ACTION_REQUIRED');
});

const bridgeStatusLabel = computed(() => {
  return bridge.value?.healthy
    ? t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.HEALTHY')
    : t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.ATTENTION_REQUIRED');
});

const readyInboxesLabel = computed(() => {
  const readyCount = account.value?.ready_inboxes_count ?? 0;
  const totalCount = account.value?.fonoster_inboxes_count ?? 0;
  return `${readyCount}/${totalCount}`;
});

const lastSyncedAtLabel = computed(() => {
  const value = inboxReadiness.value?.last_synced_at;
  if (!value) {
    return t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NOT_SYNCED');
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return date.toLocaleString();
});

const virtualPbxProviderLabel = computed(() => {
  return (
    virtualPbxConfig.value?.provider_template?.label ||
    virtualPbxConfig.value?.provider_kind ||
    t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NO_DATA')
  );
});

const virtualPbxPhoneSplitLabel = computed(() => {
  const display = virtualPbxPhoneNumbers.value?.display_phone_number;
  const ingress = virtualPbxPhoneNumbers.value?.ingress_number;

  if (display && ingress && display !== ingress) {
    return `${display} → ${ingress}`;
  }

  return display || ingress || t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NO_DATA');
});

const virtualPbxOwnershipLabel = computed(() => {
  const ownership = virtualPbxConfig.value?.ownership;
  if (!ownership) {
    return t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NO_DATA');
  }

  return ownership.read_only
    ? t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LEGACY_READ_ONLY')
    : t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.MANAGED_LOCAL');
});

const virtualPbxDetails = computed(() => [
  {
    label: t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.DISPLAY_PHONE'),
    value: virtualPbxPhoneNumbers.value?.display_phone_number,
  },
  {
    label: t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.INGRESS_NUMBER'),
    value: virtualPbxPhoneNumbers.value?.ingress_number,
  },
  {
    label: t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NUMBER_REF'),
    value: virtualPbxResources.value?.number_ref,
  },
  {
    label: t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.TRUNK_REF'),
    value: virtualPbxResources.value?.trunk_ref,
  },
  {
    label: t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.PROVIDER_CONNECTION'),
    value: virtualPbxResources.value?.provider_connection?.name,
  },
  {
    label: t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.SIP_PROFILES'),
    value: virtualPbxProfiles.value.length,
  },
]);

const statusClass = isOk => {
  return isOk ? 'bg-n-alpha-2 text-n-teal-11' : 'bg-n-alpha-2 text-n-ruby-11';
};

const errorMessageFrom = error => {
  return (
    error?.response?.data?.error ||
    error?.message ||
    t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LOAD_ERROR')
  );
};

const fetchReadiness = async () => {
  if (!isFonosterVoiceInbox.value || !props.inbox?.id) {
    readinessPayload.value = null;
    virtualPbxPayload.value = null;
    loadError.value = '';
    partialLoadError.value = '';
    return;
  }

  isLoading.value = true;
  loadError.value = '';
  partialLoadError.value = '';

  try {
    const [readinessResult, virtualPbxResult] = await Promise.allSettled([
      VoiceAPI.getReadiness(),
      VoiceAPI.getVirtualPbxReadiness(props.inbox.id),
    ]);

    if (readinessResult.status === 'rejected') {
      throw readinessResult.reason;
    }

    readinessPayload.value = readinessResult.value?.payload || null;

    if (virtualPbxResult.status === 'fulfilled') {
      virtualPbxPayload.value = virtualPbxResult.value?.payload || null;
    } else {
      virtualPbxPayload.value = null;
      partialLoadError.value = errorMessageFrom(virtualPbxResult.reason);
    }
  } catch (error) {
    readinessPayload.value = null;
    virtualPbxPayload.value = null;
    loadError.value = errorMessageFrom(error);
  } finally {
    isLoading.value = false;
  }
};

watch(
  () => [props.inbox?.id, props.inbox?.provider, props.inbox?.channel_type],
  () => {
    fetchReadiness();
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex flex-col gap-4">
    <div class="flex items-center justify-between gap-3">
      <span
        class="inline-flex items-center rounded-md px-2 py-1 text-xs font-medium"
        :class="statusClass(isReady)"
      >
        {{ readinessStatusLabel }}
      </span>
      <button
        type="button"
        class="text-sm font-medium text-n-brand hover:opacity-80"
        @click="fetchReadiness"
      >
        {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.REFRESH') }}
      </button>
    </div>

    <div v-if="isLoading" class="text-sm text-n-slate-11">
      {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LOADING') }}
    </div>

    <div
      v-else-if="loadError"
      class="rounded-xl border border-n-ruby-4 bg-n-ruby-2/40 p-4 text-sm text-n-ruby-11"
    >
      {{ loadError }}
    </div>

    <template v-else-if="inboxReadiness">
      <div
        v-if="partialLoadError"
        class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4 text-sm text-n-amber-11"
      >
        {{ partialLoadError }}
      </div>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4">
        <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
          <div
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.STATUS') }}
          </div>
          <div class="mt-2 text-sm font-medium text-n-slate-12">
            {{ readinessStatusLabel }}
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
          <div
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.BRIDGE_HEALTH') }}
          </div>
          <div class="mt-2 text-sm font-medium text-n-slate-12">
            {{ bridgeStatusLabel }}
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
          <div
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.READY_INBOXES') }}
          </div>
          <div class="mt-2 text-sm font-medium text-n-slate-12">
            {{ readyInboxesLabel }}
          </div>
        </div>

        <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
          <div
            class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.CALL_SURFACE') }}
          </div>
          <div class="mt-2 text-sm font-medium text-n-slate-12">
            {{ $t('CONVERSATION.VOICE_WIDGET.HANDLED_OUTSIDE_BROWSER') }}
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <div
          class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
        >
          {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LAST_SYNCED_AT') }}
        </div>
        <div class="mt-2 text-sm font-medium text-n-slate-12">
          {{ lastSyncedAtLabel }}
        </div>
      </div>

      <div
        v-if="virtualPbxConfig"
        data-testid="virtual-pbx-diagnostics"
        class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
      >
        <div class="flex flex-col gap-1">
          <div class="text-sm font-medium text-n-slate-12">
            {{
              $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.VIRTUAL_PBX_DIAGNOSTICS')
            }}
          </div>
          <div class="text-sm text-n-slate-11">
            {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.VIRTUAL_PBX_SAFE_MODE') }}
          </div>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-xl border border-n-weak bg-n-alpha-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.PROVIDER_KIND') }}
            </div>
            <div class="mt-2 text-sm font-medium text-n-slate-12">
              {{ virtualPbxProviderLabel }}
            </div>
          </div>

          <div class="rounded-xl border border-n-weak bg-n-alpha-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.PHONE_SPLIT') }}
            </div>
            <div class="mt-2 text-sm font-medium text-n-slate-12">
              {{ virtualPbxPhoneSplitLabel }}
            </div>
          </div>

          <div class="rounded-xl border border-n-weak bg-n-alpha-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.OWNERSHIP') }}
            </div>
            <div class="mt-2 text-sm font-medium text-n-slate-12">
              {{ virtualPbxOwnershipLabel }}
            </div>
          </div>

          <div class="rounded-xl border border-n-weak bg-n-alpha-1 p-4">
            <div
              class="text-xs font-medium uppercase tracking-wide text-n-slate-10"
            >
              {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.REMOTE_MUTATIONS') }}
            </div>
            <div class="mt-2 text-sm font-medium text-n-slate-12">
              {{
                $t(
                  'INBOX_MGMT.ADD.VOICE.CONFIGURATION.REMOTE_MUTATIONS_BLOCKED'
                )
              }}
            </div>
          </div>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
          <div
            v-for="detail in virtualPbxDetails"
            :key="detail.label"
            class="min-w-0 rounded-lg bg-n-alpha-1 px-3 py-2"
          >
            <div class="text-xs text-n-slate-10">
              {{ detail.label }}
            </div>
            <div class="mt-1 truncate text-sm font-mono text-n-slate-12">
              {{
                detail.value ?? $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NO_DATA')
              }}
            </div>
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-2">
        <div class="text-sm font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.WARNINGS_TITLE') }}
        </div>

        <template v-if="warnings.length">
          <div
            v-for="warning in warnings"
            :key="`${warning.code}-${warning.message}`"
            class="rounded-xl border border-n-amber-4 bg-n-amber-2/40 p-4"
          >
            <div class="text-sm font-medium text-n-slate-12">
              {{ warning.message }}
            </div>
            <div class="mt-1 text-xs font-mono text-n-slate-10">
              {{ warning.code }}
            </div>
          </div>
        </template>

        <div
          v-else
          class="rounded-xl border border-n-teal-4 bg-n-teal-2/40 p-4 text-sm text-n-teal-11"
        >
          {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NO_WARNINGS') }}
        </div>
      </div>
    </template>

    <div
      v-else
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4 text-sm text-n-slate-11"
    >
      {{ $t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.NO_DATA') }}
    </div>
  </div>
</template>
