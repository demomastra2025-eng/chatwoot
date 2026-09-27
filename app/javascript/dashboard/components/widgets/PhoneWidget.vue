<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { useCallsStore } from 'dashboard/stores/calls';
import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';

const SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
  'wazo',
]);
const STANDBY_REASON = 'sip_profile_registration_lease_owned_by_another_tab';
const STATUS_KEYS = {
  ready: 'SIDEBAR.SIP_TELEPHONY.STATUS.READY',
  connecting: 'SIDEBAR.SIP_TELEPHONY.STATUS.CONNECTING',
  disconnected: 'SIDEBAR.SIP_TELEPHONY.STATUS.DISCONNECTED',
  standby: 'SIDEBAR.SIP_TELEPHONY.STATUS.ACTIVE_IN_ANOTHER_TAB',
  error: 'SIDEBAR.SIP_TELEPHONY.STATUS.ERROR',
};
const dialKeys = [
  ['1', ''],
  ['2', 'ABC'],
  ['3', 'DEF'],
  ['4', 'GHI'],
  ['5', 'JKL'],
  ['6', 'MNO'],
  ['7', 'PQRS'],
  ['8', 'TUV'],
  ['9', 'WXYZ'],
  ['*', ''],
  ['0', '+'],
  ['#', ''],
];

const { t } = useI18n();
const inboxes = useMapGetter('inboxes/getInboxes');
const accountId = useMapGetter('getCurrentAccountId');
const callsStore = useCallsStore();
const phone = ref('');
const selectedInboxId = ref(null);
const isHidden = ref(false);
const isExpanded = ref(false);
const isBootstrapping = ref(false);
const hasBootstrapped = ref(false);
const sipSessions = ref([]);
const connectingKeys = ref(new Set());
const callButton = ref(null);

const voiceInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox =>
      inbox.channel_type === INBOX_TYPES.VOICE &&
      SIP_PROVIDERS.has(inbox.provider)
  )
);
// The inbox index contains account-wide channels; only the token bootstrap
// returns enabled browser-webphone sessions belonging to this user.
const availableVoiceInboxes = computed(() =>
  voiceInboxes.value.filter(inbox =>
    sipSessions.value.some(
      session => String(session.inboxId) === String(inbox.id)
    )
  )
);
const selectedInbox = computed(() =>
  availableVoiceInboxes.value.find(
    inbox => String(inbox.id) === String(selectedInboxId.value)
  )
);
const selectedSessions = computed(() =>
  sipSessions.value.filter(
    session => String(session.inboxId) === String(selectedInboxId.value)
  )
);
const selectedSession = computed(
  () =>
    selectedSessions.value.find(session => session.registered === true) ||
    selectedSessions.value[0]
);
const dialNumber = computed(() => phone.value.replace(/[\s()-]/g, ''));
const canDial = computed(() => /^\+?\d{3,20}$/.test(dialNumber.value));
const hasCall = computed(
  () => callsStore.hasActiveCall || callsStore.hasIncomingCall
);

const syncSessions = () => {
  const inboxIds = new Set(voiceInboxes.value.map(inbox => String(inbox.id)));
  sipSessions.value = Object.values(WebphoneClient.sessions)
    .filter(
      session =>
        SIP_PROVIDERS.has(session?.provider) &&
        inboxIds.has(String(session.inboxId))
    )
    .map(session => ({ ...session }));
};
const sessionStatus = session => {
  if (!session) return isBootstrapping.value ? 'connecting' : 'disconnected';
  if (connectingKeys.value.has(session.sessionKey)) return 'connecting';
  if (session.registered === true) return 'ready';
  if (session.reason === STANDBY_REASON) return 'standby';
  if (
    session.callingSupported === false ||
    /error|fail|timeout|auth|credential|password/i.test(session.reason || '')
  ) {
    return 'error';
  }
  return 'disconnected';
};
const status = computed(() => sessionStatus(selectedSession.value));
const statusLabel = computed(() =>
  hasCall.value ? t('PHONE_WIDGET.IN_CALL') : t(STATUS_KEYS[status.value])
);
const statusColor = computed(() => {
  if (hasCall.value || status.value === 'ready') return 'bg-n-teal-9';
  if (status.value === 'connecting') return 'bg-n-amber-9';
  if (status.value === 'standby') return 'bg-n-slate-9';
  return 'bg-n-ruby-9';
});

const bootstrap = async () => {
  if (!voiceInboxes.value.length || hasBootstrapped.value) return;
  hasBootstrapped.value = true;
  isBootstrapping.value = true;
  try {
    await WebphoneClient.bootstrapIncomingSupport();
  } catch {
    // Existing sessions remain visible and retryable if registration fails.
  } finally {
    isBootstrapping.value = false;
    syncSessions();
  }
};
const reconnect = async session => {
  if (['ready', 'connecting', 'standby'].includes(sessionStatus(session)))
    return;
  connectingKeys.value = new Set([...connectingKeys.value, session.sessionKey]);
  try {
    await WebphoneClient.initializeDevice(session.inboxId, {
      native: true,
      provider: session.provider,
      sipProfileId: session.sipProfileId,
      sessionKey: session.sessionKey,
    });
  } catch {
    // The session status is still displayed and can be retried.
  } finally {
    connectingKeys.value = new Set(
      [...connectingKeys.value].filter(key => key !== session.sessionKey)
    );
    syncSessions();
  }
};
const appendKey = key => {
  phone.value += key;
};
const appendPlus = () => {
  if (!phone.value.startsWith('+')) phone.value = `+${phone.value}`;
};
const removeLastKey = () => {
  phone.value = phone.value.slice(0, -1);
};
const dialOnEnter = () => {
  if (canDial.value && selectedInbox.value) callButton.value?.onClick();
};

watch(
  availableVoiceInboxes,
  () => {
    if (
      !availableVoiceInboxes.value.some(
        inbox => String(inbox.id) === String(selectedInboxId.value)
      )
    ) {
      selectedInboxId.value = availableVoiceInboxes.value[0]?.id || null;
    }
  },
  { immediate: true }
);
watch(
  voiceInboxes,
  () => {
    syncSessions();
    bootstrap();
  },
  { immediate: true }
);
watch(accountId, () => {
  hasBootstrapped.value = false;
  bootstrap();
});
onMounted(() => {
  WebphoneClient.addEventListener('call:sessions-changed', syncSessions);
  syncSessions();
});
onUnmounted(() => {
  WebphoneClient.removeEventListener('call:sessions-changed', syncSessions);
});
</script>

<template>
  <div
    v-if="availableVoiceInboxes.length"
    class="fixed ltr:right-4 rtl:left-4 top-16 z-40 w-[320px] max-w-[calc(100vw-2rem)]"
    data-testid="phone-widget"
  >
    <button
      v-if="isHidden"
      type="button"
      class="ms-auto flex items-center gap-2 rounded-full border border-n-strong bg-n-solid-2 px-3 py-2.5 text-n-slate-12 shadow-xl hover:bg-n-alpha-2"
      :aria-label="t('PHONE_WIDGET.OPEN')"
      :title="statusLabel"
      data-testid="phone-widget-launcher"
      @click="isHidden = false"
    >
      <i class="i-lucide-phone size-5" aria-hidden="true" />
      <span
        class="size-2 rounded-full"
        :class="statusColor"
        aria-hidden="true"
      />
    </button>
    <section
      v-else
      class="overflow-hidden rounded-xl border border-n-strong bg-n-solid-2 text-n-slate-12 shadow-xl"
      :aria-label="t('PHONE_WIDGET.TITLE')"
      data-testid="phone-widget-panel"
    >
      <header
        class="flex items-center gap-2 border-b border-n-weak px-3 py-2.5"
      >
        <span
          class="flex size-8 items-center justify-center rounded-lg bg-n-teal-3 text-n-teal-11"
        >
          <i class="i-lucide-phone size-4" aria-hidden="true" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="truncate text-sm font-semibold">
            {{ t('PHONE_WIDGET.TITLE') }}
          </div>
          <div
            class="flex items-center gap-1.5 text-xs text-n-slate-11"
            role="status"
          >
            <span
              class="size-1.5 rounded-full"
              :class="statusColor"
              aria-hidden="true"
            />
            {{ statusLabel }}
          </div>
        </div>
        <button
          type="button"
          class="flex size-8 items-center justify-center rounded-md hover:bg-n-alpha-2"
          :aria-label="
            isExpanded ? t('PHONE_WIDGET.MINIMIZE') : t('PHONE_WIDGET.EXPAND')
          "
          data-testid="phone-widget-expand"
          @click="isExpanded = !isExpanded"
        >
          <i
            :class="isExpanded ? 'i-lucide-minus' : 'i-lucide-grid-3x3'"
            class="size-4"
            aria-hidden="true"
          />
        </button>
        <button
          type="button"
          class="flex size-8 items-center justify-center rounded-md hover:bg-n-alpha-2"
          :aria-label="t('PHONE_WIDGET.HIDE')"
          data-testid="phone-widget-hide"
          @click="isHidden = true"
        >
          <i class="i-lucide-x size-4" aria-hidden="true" />
        </button>
      </header>

      <div class="px-3 py-3">
        <div v-if="availableVoiceInboxes.length > 1" class="mb-3">
          <label
            class="mb-1 block text-xs text-n-slate-11"
            for="phone-widget-inbox"
          >
            {{ t('PHONE_WIDGET.LINE') }}
          </label>
          <select
            id="phone-widget-inbox"
            v-model="selectedInboxId"
            class="w-full rounded-md border border-n-strong bg-n-solid-1 px-2 py-1.5 text-sm text-n-slate-12"
            data-testid="phone-widget-inbox"
          >
            <option
              v-for="inbox in availableVoiceInboxes"
              :key="inbox.id"
              :value="inbox.id"
            >
              {{ inbox.name }}
            </option>
          </select>
        </div>

        <div class="flex items-center gap-2">
          <input
            v-model="phone"
            type="tel"
            inputmode="tel"
            autocomplete="off"
            class="min-w-0 flex-1 rounded-lg border border-n-strong bg-n-solid-1 px-3 py-2 text-sm outline-none focus:border-n-teal-9"
            :placeholder="t('PHONE_WIDGET.NUMBER_PLACEHOLDER')"
            :aria-label="t('PHONE_WIDGET.NUMBER_PLACEHOLDER')"
            data-testid="phone-widget-number"
            @keyup.enter="dialOnEnter"
          />
          <VoiceCallButton
            v-if="canDial && selectedInbox"
            ref="callButton"
            :phone="dialNumber"
            :inbox-id="selectedInbox.id"
            :disabled="hasCall"
            :label="t('PHONE_WIDGET.CALL')"
            icon="i-lucide-phone-call"
            @call-initiated="isExpanded = false"
          />
          <button
            v-else
            type="button"
            disabled
            class="rounded-lg bg-n-teal-9 px-3 py-2 text-sm font-medium text-white opacity-50"
            :aria-label="t('PHONE_WIDGET.CALL')"
          >
            <i class="i-lucide-phone-call size-4" aria-hidden="true" />
          </button>
        </div>
        <div
          v-if="isExpanded"
          class="mt-3 border-t border-n-weak pt-3"
          data-testid="phone-widget-expanded"
        >
          <div class="mb-3 grid grid-cols-3 gap-2">
            <button
              v-for="[key, letters] in dialKeys"
              :key="key"
              type="button"
              class="flex h-12 flex-col items-center justify-center rounded-lg border border-n-weak bg-n-solid-1 text-lg font-medium leading-5 hover:border-n-teal-9 hover:bg-n-teal-2"
              :aria-label="key"
              :data-testid="`phone-key-${key}`"
              @click="appendKey(key)"
            >
              {{ key }}
              <span
                class="text-[9px] font-normal tracking-wider text-n-slate-10"
                >{{ letters || '\u00a0' }}</span
              >
            </button>
          </div>
          <div
            class="flex items-center justify-between gap-2 text-xs text-n-slate-11"
          >
            <button
              type="button"
              class="rounded-md px-2 py-1 text-base font-medium hover:bg-n-alpha-2"
              :aria-label="t('PHONE_WIDGET.ADD_PLUS')"
              data-testid="phone-widget-plus"
              @click="appendPlus"
            >
              +
            </button>
            <button
              type="button"
              class="flex items-center gap-1 hover:text-n-slate-12"
              :aria-label="t('PHONE_WIDGET.DELETE_DIGIT')"
              @click="removeLastKey"
            >
              <i class="i-lucide-delete size-4" aria-hidden="true" />
              {{ t('PHONE_WIDGET.DELETE_DIGIT') }}
            </button>
            <button
              v-if="
                selectedSession && ['disconnected', 'error'].includes(status)
              "
              type="button"
              class="text-n-teal-11 hover:underline"
              data-testid="phone-widget-reconnect"
              @click="reconnect(selectedSession)"
            >
              {{ t('SIDEBAR.SIP_TELEPHONY.RECONNECT') }}
            </button>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
