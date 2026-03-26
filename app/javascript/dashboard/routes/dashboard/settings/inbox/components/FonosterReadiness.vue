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
const isLoading = ref(false);
const loadError = ref('');

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

const accountWarnings = computed(() => {
  const warnings = readinessPayload.value?.warnings || [];
  return warnings.filter(
    warning =>
      !['inboxes_not_ready', 'no_fonoster_inboxes'].includes(warning.code)
  );
});

const warnings = computed(() => {
  return [...accountWarnings.value, ...(inboxReadiness.value?.warnings || [])];
});

const isReady = computed(() => {
  return Boolean(bridge.value?.healthy && inboxReadiness.value?.ready);
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

const statusClass = isOk => {
  return isOk ? 'bg-n-alpha-2 text-n-teal-11' : 'bg-n-alpha-2 text-n-ruby-11';
};

const fetchReadiness = async () => {
  if (!isFonosterVoiceInbox.value) {
    readinessPayload.value = null;
    loadError.value = '';
    return;
  }

  isLoading.value = true;
  loadError.value = '';

  try {
    const response = await VoiceAPI.getReadiness();
    readinessPayload.value = response?.payload || null;
  } catch (error) {
    readinessPayload.value = null;
    loadError.value =
      error?.response?.data?.error ||
      error?.message ||
      t('INBOX_MGMT.ADD.VOICE.CONFIGURATION.LOAD_ERROR');
  } finally {
    isLoading.value = false;
  }
};

watch(
  () => [props.inbox?.id, props.inbox?.provider],
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
