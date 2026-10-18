<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useSipMicrophone } from 'dashboard/composables/useSipMicrophone';
import { useCallNotificationPermission } from 'dashboard/composables/useIncomingCallAttention';
import { usePhoneWidgetVisibility } from 'dashboard/composables/usePhoneWidgetVisibility';
import { usePhoneWidgetPosition } from 'dashboard/composables/usePhoneWidgetPosition';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { normalizeDialNumber } from 'dashboard/helper/phoneDialNumber';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';
import { useCallsStore } from 'dashboard/stores/calls';
import {
  phoneLineProviderLabel,
  phoneWidgetStatusColor,
  usePhoneWidgetStore,
} from 'dashboard/stores/phoneWidget';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import VoiceCallButton from 'dashboard/components-next/Contacts/VoiceCallButton.vue';
import FloatingCallWidget from 'dashboard/components/widgets/FloatingCallWidget.vue';
import WhatsappCallWidget from 'dashboard/components/widgets/WhatsappCallWidget.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';

const SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
  'wazo',
]);
const STANDBY_REASON = 'sip_profile_registration_lease_owned_by_another_tab';
const OWNER_TAB_BUSY_REASON = 'webphone_owner_tab_busy';
// Moving the phone between tabs removes its SIP session in both tabs until the
// new owner registers; keep the line on screen as "connecting" meanwhile
// instead of hiding the whole phone.
const HANDOVER_GRACE_MS = 15_000;
const ACTIONABLE_STATUSES = ['disconnected', 'error', 'ownerTab'];
const dialKeys = ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

const { t } = useI18n();
const inboxes = useMapGetter('inboxes/getInboxes');
const accountId = useMapGetter('getCurrentAccountId');
const currentUser = useMapGetter('getCurrentUser');
const callsStore = useCallsStore();
const phoneWidgetStore = usePhoneWidgetStore();
const whatsappCallsStore = useWhatsappCallsStore();
// Hiding only takes the widget off screen (v-show): this component and its
// call list stay mounted, so the SIP sessions keep running, browser SIP
// INVITEs are still reported and put in the calls store, and a new incoming
// call brings the phone back and rings.
const { hasCallActivity, isVisible, ownIncomingCalls, hide } =
  usePhoneWidgetVisibility();
const phone = ref('');
const selectedInboxId = ref(phoneWidgetStore.selectedInboxId || null);
const isExpanded = ref(false);
const isBootstrapping = ref(false);
const hasBootstrapped = ref(false);
const sipSessions = ref([]);
const connectingKeys = ref(new Set());
const callButton = ref(null);
const widgetRef = ref(null);
// Dragged by its header anywhere on screen, never past the window edges.
const { position, positionStyle, isDragging, startDrag, scheduleClamp } =
  usePhoneWidgetPosition(widgetRef);
let handoverTimer = null;

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
// Once this user has a browser SIP line, keep the phone (and the embedded call
// cards with their SIP listeners) mounted. Live sessions briefly disappear while
// a line re-registers; unmounting then lost incoming INVITEs and every remount
// fetched a new webphone token, which triggered yet another re-registration.
const hasBrowserLine = ref(false);
watch(
  () => availableVoiceInboxes.value.length > 0,
  hasLine => {
    if (hasLine) hasBrowserLine.value = true;
  },
  { immediate: true }
);
watch(
  () => voiceInboxes.value.length,
  count => {
    if (count === 0) hasBrowserLine.value = false;
  }
);

const whatsappVoiceInboxes = computed(() =>
  (inboxes.value || []).filter(
    inbox =>
      inbox.channel_type === INBOX_TYPES.WHATSAPP &&
      (inbox.calling_enabled === true ||
        inbox.provider_config?.calling_enabled === true ||
        (hasBrowserLine.value && inbox.can_call === true))
  )
);
const hasWhatsappCallingInbox = computed(() =>
  (inboxes.value || []).some(
    inbox =>
      inbox.channel_type === INBOX_TYPES.WHATSAPP &&
      (inbox.calling_enabled === true ||
        inbox.provider_config?.calling_enabled === true)
  )
);

const whatsappIncomingCalls = computed(() =>
  Array.isArray(whatsappCallsStore?.incomingCalls)
    ? whatsappCallsStore.incomingCalls
    : []
);
const hasWhatsappActiveCall = computed(() =>
  Boolean(whatsappCallsStore?.hasActiveCall || whatsappCallsStore?.activeCall)
);
const hasWhatsappIncomingCall = computed(() =>
  Boolean(
    whatsappCallsStore?.hasIncomingCall ||
      whatsappIncomingCalls.value.length > 0
  )
);
const hasWhatsappCall = computed(
  () => hasWhatsappActiveCall.value || hasWhatsappIncomingCall.value
);

const allCallableInboxes = computed(() => [
  ...availableVoiceInboxes.value,
  ...whatsappVoiceInboxes.value,
]);

const selectedInbox = computed(
  () =>
    availableVoiceInboxes.value.find(
      inbox => String(inbox.id) === String(selectedInboxId.value)
    ) ||
    allCallableInboxes.value.find(
      inbox => String(inbox.id) === String(selectedInboxId.value)
    ) ||
    availableVoiceInboxes.value[0] ||
    null
);
const sessionsForInbox = inboxId =>
  sipSessions.value.filter(
    session => String(session.inboxId) === String(inboxId)
  );
const bestSessionForInbox = inboxId => {
  const sessions = sessionsForInbox(inboxId);
  return (
    sessions.find(session => session.registered === true) || sessions[0] || null
  );
};
const selectedSessions = computed(() =>
  sessionsForInbox(selectedInboxId.value)
);
const selectedSession = computed(
  () =>
    selectedSessions.value.find(session => session.registered === true) ||
    selectedSessions.value[0]
);
const dialNumber = computed(() => normalizeDialNumber(phone.value));
const canDial = computed(() => Boolean(dialNumber.value));
const hasCall = computed(
  () =>
    callsStore.hasActiveCall ||
    callsStore.hasIncomingCall ||
    hasWhatsappCall.value
);
// The employee's own call (ringing, being dialled or connected) is shown in
// the phone itself instead of the dialer; there is no second call window.
const hasOwnCall = computed(() =>
  Boolean(
    callsStore.hasActiveCall ||
      ownIncomingCalls.value.length ||
      hasWhatsappCall.value
  )
);
const callState = computed(() => {
  if (
    callsStore.hasActiveCall ||
    (hasWhatsappActiveCall.value &&
      whatsappCallsStore?.activeCall?.status !== 'ringing')
  ) {
    return 'active';
  }
  if (
    ownIncomingCalls.value.some(call => call?.callDirection !== 'outbound') ||
    hasWhatsappIncomingCall.value
  ) {
    return 'incoming';
  }
  if (
    ownIncomingCalls.value.length ||
    phoneWidgetStore.preparingOutboundCalls > 0 ||
    (hasWhatsappActiveCall.value &&
      whatsappCallsStore?.activeCall?.status === 'ringing')
  ) {
    return 'dialing';
  }
  return 'idle';
});
const activeCall = computed(() => callsStore.activeCall);
const { microphoneAvailable, microphoneMuted, toggleMicrophone } =
  useSipMicrophone(activeCall);
const microphoneLabel = computed(() => {
  if (!microphoneAvailable.value) {
    return t('PHONE_WIDGET.MICROPHONE_UNAVAILABLE');
  }
  return microphoneMuted.value
    ? t('PHONE_WIDGET.MICROPHONE_MUTED')
    : t('PHONE_WIDGET.MUTE_MICROPHONE');
});
const { uiSettings, updateUISettings } = useUISettings();
const ringtoneEnabled = computed(
  () => uiSettings.value?.voice_call_ringtone_enabled !== false
);
// Like the microphone, the ringtone button is an "off" switch: it is pressed
// (filled red, aria-pressed) while incoming calls ring without sound.
const ringtoneLabel = computed(() =>
  ringtoneEnabled.value
    ? t('PHONE_WIDGET.DISABLE_RINGTONE')
    : t('PHONE_WIDGET.RINGTONE_MUTED')
);
const toggleRingtone = () => {
  updateUISettings({ voice_call_ringtone_enabled: !ringtoneEnabled.value });
};
const { canRequestCallNotifications, requestCallNotifications } =
  useCallNotificationPermission();

const clearHandoverTimer = () => {
  if (handoverTimer) clearTimeout(handoverTimer);
  handoverTimer = null;
};
const syncSessions = () => {
  const inboxIds = new Set(voiceInboxes.value.map(inbox => String(inbox.id)));
  const liveSessions = Object.values(WebphoneClient.sessions)
    .filter(
      session =>
        SIP_PROVIDERS.has(session?.provider) &&
        inboxIds.has(String(session.inboxId))
    )
    .map(session => ({ ...session }));
  const liveKeys = new Set(liveSessions.map(session => session.sessionKey));
  const now = Date.now();
  const handoverSessions = sipSessions.value
    .filter(
      session =>
        !liveKeys.has(session.sessionKey) &&
        inboxIds.has(String(session.inboxId))
    )
    .map(session => ({
      ...session,
      handoverUntil: session.handoverUntil || now + HANDOVER_GRACE_MS,
    }))
    .filter(session => session.handoverUntil > now);
  sipSessions.value = [...liveSessions, ...handoverSessions];

  clearHandoverTimer();
  if (handoverSessions.length) {
    const expiresAt = Math.min(
      ...handoverSessions.map(session => session.handoverUntil)
    );
    handoverTimer = setTimeout(syncSessions, expiresAt - now);
  }
};
const sessionStatus = session => {
  if (!session) return isBootstrapping.value ? 'connecting' : 'disconnected';
  if (session.handoverUntil) return 'connecting';
  if (connectingKeys.value.has(session.sessionKey)) return 'connecting';
  // Another tab of this browser owns the phone and mirrors its registration.
  if (session.mirrored && session.registered === true) return 'ownerTab';
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
const lineStatusLabel = value => {
  switch (value) {
    case 'ready':
      return 'Активен';
    case 'ownerTab':
    case 'standby':
      return 'В другой вкладке';
    case 'connecting':
      return 'Подключение...';
    case 'error':
      return 'Ошибка';
    default:
      return 'Отключён';
  }
};
const allPhoneLines = computed(() => {
  const sipLines = availableVoiceInboxes.value.map(inbox => {
    const session = bestSessionForInbox(inbox.id);
    const lineStatus = sessionStatus(session);
    const phoneNumber = inbox.phone_number || inbox.phoneNumber || '';
    return {
      id: inbox.id,
      inbox,
      name: inbox.name || `Line ${inbox.id}`,
      phoneNumber,
      provider: inbox.provider,
      providerLabel: phoneLineProviderLabel(inbox),
      isWhatsapp: false,
      session,
      status: lineStatus,
      statusColor: phoneWidgetStatusColor(lineStatus),
      statusLabel: lineStatusLabel(lineStatus),
      canReconnect: ACTIONABLE_STATUSES.includes(lineStatus),
      movesHere:
        ACTIONABLE_STATUSES.includes(lineStatus) && session?.mirrored === true,
    };
  });

  const whatsappLines = whatsappVoiceInboxes.value.map(inbox => {
    const phoneNumber =
      inbox.phone_number ||
      inbox.phoneNumber ||
      inbox.provider_config?.phone_number ||
      '';
    return {
      id: inbox.id,
      inbox,
      name: inbox.name || 'WhatsApp',
      phoneNumber,
      provider: 'whatsapp_cloud',
      providerLabel: 'WhatsApp',
      isWhatsapp: true,
      session: null,
      status: 'ready',
      statusColor: phoneWidgetStatusColor('ready'),
      statusLabel: lineStatusLabel('ready'),
      canReconnect: false,
      movesHere: false,
    };
  });

  return [...sipLines, ...whatsappLines];
});
const linesStatusById = computed(() =>
  Object.fromEntries(
    allPhoneLines.value.map(line => [String(line.id), line.status])
  )
);
const selectedLineLabel = 'Выбрана для звонка';

const status = computed(() => {
  if (
    !availableVoiceInboxes.value.length &&
    (hasWhatsappCallingInbox.value || hasWhatsappCall.value)
  ) {
    return 'ready';
  }
  return sessionStatus(selectedSession.value);
});
// Literal keys keep every status label visible to the i18n tooling.
const statusText = value => {
  switch (value) {
    case 'ready':
      return t('SIDEBAR.SIP_TELEPHONY.STATUS.READY');
    case 'ownerTab':
      return t('SIDEBAR.SIP_TELEPHONY.STATUS.READY_IN_OWNER_TAB');
    case 'connecting':
      return t('SIDEBAR.SIP_TELEPHONY.STATUS.CONNECTING');
    case 'standby':
      return t('SIDEBAR.SIP_TELEPHONY.STATUS.ACTIVE_IN_ANOTHER_TAB');
    case 'error':
      return t('SIDEBAR.SIP_TELEPHONY.STATUS.ERROR');
    default:
      return t('SIDEBAR.SIP_TELEPHONY.STATUS.DISCONNECTED');
  }
};
const statusLabel = computed(() =>
  hasCall.value && status.value === 'ready'
    ? t('PHONE_WIDGET.IN_CALL')
    : statusText(status.value)
);
const employeeName = computed(
  () =>
    currentUser.value?.name?.trim() ||
    currentUser.value?.available_name?.trim() ||
    t('PHONE_WIDGET.EMPLOYEE')
);
const employeeStatusLabel = computed(
  () => `${employeeName.value} · ${statusLabel.value}`
);
const connectionLabel = computed(() => {
  if (status.value === 'ready') return t('PHONE_WIDGET.ACTIVE');
  if (status.value === 'standby') return t('PHONE_WIDGET.OTHER_TAB');
  return statusLabel.value;
});
const actionableSessions = computed(() =>
  sipSessions.value.filter(session =>
    ACTIONABLE_STATUSES.includes(sessionStatus(session))
  )
);
const canUseConnectionAction = computed(
  () =>
    ACTIONABLE_STATUSES.includes(status.value) ||
    actionableSessions.value.length > 0
);
// A mirrored line is registered by another tab: the action moves the phone
// here instead of refreshing a connection this tab does not hold.
const movesPhoneHere = computed(
  () =>
    canUseConnectionAction.value &&
    (selectedSession.value?.mirrored === true ||
      (actionableSessions.value.length > 0 &&
        actionableSessions.value.every(session => session?.mirrored === true)))
);
const connectionActionIcon = computed(() =>
  movesPhoneHere.value ? 'i-lucide-monitor-down' : 'i-lucide-refresh-cw'
);
const connectionActionLabel = computed(() => {
  if (movesPhoneHere.value) return t('PHONE_WIDGET.MOVE_HERE');
  if (canUseConnectionAction.value) return t('PHONE_WIDGET.REFRESH_CONNECTION');
  return connectionLabel.value;
});
const statusColor = computed(() => phoneWidgetStatusColor(status.value));
// Incoming calls the employee has not seen yet: each new one shows the phone
// again even if it was hidden during an earlier call. Calls a colleague took
// do not count.
const incomingCallKeys = computed(() => [
  ...ownIncomingCalls.value
    .filter(call => call?.callDirection !== 'outbound' && call?.callSid)
    .map(call => String(call.callSid)),
  ...whatsappIncomingCalls.value
    .map(call => String(call?.callId || call?.id || ''))
    .filter(Boolean),
]);

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
  if (!session || !ACTIONABLE_STATUSES.includes(sessionStatus(session))) return;
  connectingKeys.value = new Set([...connectingKeys.value, session.sessionKey]);
  try {
    // An explicit connect means "use the phone in this tab": a tab that only
    // mirrors the owner takes the phone over (the owner refuses mid-call).
    await WebphoneClient.initializeDevice(session.inboxId, {
      native: true,
      provider: session.provider,
      sipProfileId: session.sipProfileId,
      sessionKey: session.sessionKey,
      claimOwnership: true,
    });
  } catch (error) {
    // The session status is still displayed and can be retried.
    if (error?.reason === OWNER_TAB_BUSY_REASON) {
      useAlert(t('PHONE_WIDGET.OWNER_TAB_BUSY'));
    }
  } finally {
    connectingKeys.value = new Set(
      [...connectingKeys.value].filter(key => key !== session.sessionKey)
    );
    syncSessions();
  }
};
const reconnectAllLines = async () => {
  const targets = actionableSessions.value.length
    ? actionableSessions.value
    : [selectedSession.value].filter(Boolean);
  await Promise.all(targets.map(session => reconnect(session)));
};
const selectLine = inboxId => {
  if (inboxId === null || inboxId === undefined) return;
  selectedInboxId.value = inboxId;
  phoneWidgetStore.setSelectedInboxId(inboxId);
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
// A pasted contact line ("8 (701) 123-45-67, Айгерим", several lines, ...)
// becomes the exact E.164 number that will be dialled; anything without a
// complete number is pasted as usual so it can be edited.
const pasteNumber = event => {
  // The design-system input also forwards this listener to its wrapper.
  if (event.defaultPrevented) return;
  const number = normalizeDialNumber(event.clipboardData?.getData('text'));
  if (!number) return;

  event.preventDefault();
  phone.value = number;
};
const dialOnEnter = () => {
  if (canDial.value && selectedInbox.value) callButton.value?.onClick();
};

watch(
  voiceInboxes,
  () => {
    syncSessions();
    bootstrap();
  },
  { immediate: true }
);
watch(
  [availableVoiceInboxes, whatsappVoiceInboxes],
  () => {
    const candidates = availableVoiceInboxes.value.length
      ? availableVoiceInboxes.value
      : whatsappVoiceInboxes.value;
    if (
      !allCallableInboxes.value.some(
        inbox => String(inbox.id) === String(selectedInboxId.value)
      )
    ) {
      const storedId = phoneWidgetStore.selectedInboxId;
      const storedMatch = candidates.find(
        inbox => String(inbox.id) === String(storedId)
      );
      selectedInboxId.value = storedMatch?.id || candidates[0]?.id || null;
    }
  },
  { immediate: true }
);
watch(selectedInboxId, nextId => {
  if (nextId !== null && nextId !== undefined) {
    phoneWidgetStore.setSelectedInboxId(nextId);
  }
});
watch(accountId, () => {
  hasBrowserLine.value = availableVoiceInboxes.value.length > 0;
  hasBootstrapped.value = false;
  bootstrap();
});
const hasAnyPhoneLine = computed(
  () =>
    hasBrowserLine.value ||
    hasWhatsappCallingInbox.value ||
    hasWhatsappCall.value
);
// The sidebar phone button shows the same line state as this header.
watch(
  [hasAnyPhoneLine, status, linesStatusById],
  ([available, value, linesMap]) => {
    phoneWidgetStore.publishSipState({
      available,
      status: value,
      linesStatusById: linesMap,
    });
  },
  { immediate: true }
);
watch(hasCallActivity, active => {
  if (!active) phoneWidgetStore.setCallDismissed(false);
});
watch(incomingCallKeys, (keys, previousKeys = []) => {
  if (keys.some(key => !previousKeys.includes(key))) {
    phoneWidgetStore.setCallDismissed(false);
  }
});
// The phone grows and shrinks between the dialer, the keypad and call cards;
// keep a moved phone inside the window (ResizeObserver covers the rest).
watch(
  [
    hasOwnCall,
    isExpanded,
    () => (callsStore.incomingCalls || []).length,
    () => allPhoneLines.value.length,
  ],
  scheduleClamp
);
const channelCapacity = ref(null);
const fetchChannelCapacity = async () => {
  if (!accountId.value || !selectedInboxId.value || !window.axios?.get) {
    channelCapacity.value = null;
    return;
  }
  const inbox = selectedInbox.value;
  if (inbox?.provider && inbox.provider !== 'wazo') {
    channelCapacity.value = null;
    return;
  }
  try {
    const response = await window.axios.get(
      `/api/v1/accounts/${accountId.value}/telephony/webphone/channel_capacity`,
      { params: { inbox_id: selectedInboxId.value } }
    );
    channelCapacity.value = response?.data?.capacity || null;
  } catch {
    channelCapacity.value = null;
  }
};
const channelCapacityLabel = computed(() => {
  const cap = channelCapacity.value;
  if (!cap) return '';
  const active = cap.active_channels ?? 0;
  const max = cap.effective_max_channels;
  const peak = cap.peak_today ?? active;
  return max
    ? `Линии: ${active} / ${max} · Пик сегодня: ${peak}`
    : `Активных линий: ${active} · Пик сегодня: ${peak}`;
});

watch([selectedInboxId, hasCall], () => {
  fetchChannelCapacity();
});

onMounted(() => {
  WebphoneClient.addEventListener('call:sessions-changed', syncSessions);
  syncSessions();
  fetchChannelCapacity();
});
onUnmounted(() => {
  WebphoneClient.removeEventListener('call:sessions-changed', syncSessions);
  clearHandoverTimer();
  phoneWidgetStore.publishSipState({ available: false });
});
</script>

<template>
  <div
    v-if="hasAnyPhoneLine"
    v-show="
      isVisible &&
      (availableVoiceInboxes.length > 0 ||
        hasWhatsappCallingInbox ||
        hasCall ||
        hasOwnCall)
    "
    ref="widgetRef"
    class="fixed z-40 w-[336px] max-w-[calc(100vw-2rem)]"
    :class="{ 'ltr:right-4 rtl:left-4 top-16': !position }"
    :style="positionStyle"
    :data-state="callState"
    data-testid="phone-widget"
  >
    <section
      class="flex flex-col overflow-hidden rounded-xl border border-n-strong bg-n-solid-2 text-n-slate-12 shadow-xl"
      :class="
        position ? 'max-h-[calc(100vh-1rem)]' : 'max-h-[calc(100vh-5rem)]'
      "
      :aria-label="t('PHONE_WIDGET.TITLE')"
      data-testid="phone-widget-panel"
    >
      <header
        class="flex shrink-0 touch-none select-none items-center gap-1.5 border-b border-n-weak px-4 py-3"
        :class="isDragging ? 'cursor-grabbing' : 'cursor-grab'"
        data-testid="phone-widget-drag-handle"
        @pointerdown="startDrag"
      >
        <div
          class="flex min-w-0 flex-1 items-center gap-1.5"
          role="status"
          :aria-label="employeeStatusLabel"
          :title="employeeStatusLabel"
          data-testid="phone-widget-employee"
        >
          <!-- An invisible ring around the dot enlarges the hover area, so the
               status title shows when the pointer is near the dot. -->
          <span
            class="relative size-2 shrink-0 rounded-full before:absolute before:-inset-1.5"
            :class="statusColor"
            :title="employeeStatusLabel"
            data-testid="phone-widget-status-dot"
            aria-hidden="true"
          />
          <span class="min-w-0 truncate text-sm font-medium">
            {{ employeeName }}
          </span>
        </div>
        <!-- On/off buttons: the "off" state (muted microphone, silent
             ringtone) is a filled red pressed button with its own label,
             never only another icon. -->
        <Button
          type="button"
          :variant="microphoneMuted ? 'solid' : 'ghost'"
          :color="microphoneMuted ? 'ruby' : 'slate'"
          size="sm"
          class="shrink-0"
          :icon="microphoneMuted ? 'i-lucide-mic-off' : 'i-lucide-mic'"
          :disabled="!microphoneAvailable"
          :aria-label="microphoneLabel"
          :title="microphoneLabel"
          :aria-pressed="microphoneMuted"
          data-testid="phone-widget-microphone"
          @click="toggleMicrophone"
        />
        <Button
          type="button"
          :variant="ringtoneEnabled ? 'ghost' : 'solid'"
          :color="ringtoneEnabled ? 'slate' : 'ruby'"
          size="sm"
          class="shrink-0"
          :icon="ringtoneEnabled ? 'i-lucide-bell' : 'i-lucide-bell-off'"
          :aria-label="ringtoneLabel"
          :title="ringtoneLabel"
          :aria-pressed="!ringtoneEnabled"
          data-testid="phone-widget-ringtone"
          @click="toggleRingtone"
        />
        <Button
          type="button"
          variant="ghost"
          :color="canUseConnectionAction ? 'teal' : 'slate'"
          size="sm"
          :icon="connectionActionIcon"
          class="shrink-0"
          :disabled="!canUseConnectionAction"
          :aria-label="connectionActionLabel"
          :title="connectionActionLabel"
          data-testid="phone-widget-reconnect"
          @click="reconnectAllLines"
        />
        <!-- Shows/hides the keypad (a disclosure, hence aria-expanded); an
             open keypad is a filled button. -->
        <Button
          v-if="!hasOwnCall"
          type="button"
          :variant="isExpanded ? 'solid' : 'ghost'"
          :color="isExpanded ? 'blue' : 'slate'"
          size="sm"
          class="shrink-0"
          icon="i-fluent-dialpad-20-regular"
          :aria-expanded="isExpanded"
          :aria-label="
            isExpanded ? t('PHONE_WIDGET.MINIMIZE') : t('PHONE_WIDGET.EXPAND')
          "
          :title="
            isExpanded ? t('PHONE_WIDGET.MINIMIZE') : t('PHONE_WIDGET.EXPAND')
          "
          data-testid="phone-widget-expand"
          @click="isExpanded = !isExpanded"
        />
        <Button
          type="button"
          variant="ghost"
          color="slate"
          size="sm"
          icon="i-lucide-x"
          class="shrink-0"
          :aria-label="t('PHONE_WIDGET.HIDE')"
          :title="t('PHONE_WIDGET.HIDE')"
          data-testid="phone-widget-hide"
          @click="hide"
        />
      </header>

      <div class="min-h-0 overflow-y-auto">
        <!-- Incoming, outgoing and connected calls: answer, decline, hang up
             and open the conversation right here. -->
        <!-- Always mounted: its call session listens for SIP INVITEs even
             while the phone is hidden; a hidden phone stays silent. -->
        <WhatsappCallWidget
          v-if="hasWhatsappCall"
          embedded
          :silent="!isVisible"
        />
        <FloatingCallWidget embedded :silent="!isVisible" />
        <div
          v-show="!hasOwnCall"
          class="px-4 py-3"
          data-testid="phone-widget-dialer"
        >
          <Button
            v-if="canRequestCallNotifications"
            type="button"
            variant="faded"
            color="slate"
            size="sm"
            icon="i-lucide-bell-ring"
            class="mb-2 w-full"
            :label="t('PHONE_WIDGET.ENABLE_CALL_NOTIFICATIONS')"
            data-testid="phone-widget-enable-notifications"
            @click="requestCallNotifications"
          />
          <div v-if="availableVoiceInboxes.length > 1" class="sr-only">
            <Select
              id="phone-widget-inbox"
              v-model="selectedInboxId"
              class="w-full"
              :aria-label="t('PHONE_WIDGET.LINE')"
              data-testid="phone-widget-inbox"
            >
              <option
                v-for="inbox in availableVoiceInboxes"
                :key="inbox.id"
                :value="inbox.id"
              >
                {{ inbox.name }}
              </option>
            </Select>
          </div>
          <div
            v-if="allPhoneLines.length >= 1"
            class="mb-2 flex max-h-28 flex-col gap-1 overflow-y-auto"
            data-testid="phone-widget-lines-list"
          >
            <div
              v-for="line in allPhoneLines"
              :key="line.id"
              role="button"
              tabindex="0"
              class="flex cursor-pointer items-center justify-between gap-1.5 rounded-md border px-2 py-1 text-left transition-colors"
              :class="
                String(selectedInboxId) === String(line.id)
                  ? 'border-n-teal-9 bg-n-teal-2'
                  : 'border-n-weak bg-n-alpha-1 hover:bg-n-alpha-2'
              "
              :aria-pressed="String(selectedInboxId) === String(line.id)"
              :data-line-id="String(line.id)"
              :data-line-status="line.status"
              :data-selected="
                String(String(selectedInboxId) === String(line.id))
              "
              data-testid="phone-widget-line-item"
              @click="selectLine(line.id)"
              @keydown.enter.prevent="selectLine(line.id)"
              @keydown.space.prevent="selectLine(line.id)"
            >
              <div
                class="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden"
              >
                <span
                  class="size-2 shrink-0 rounded-full"
                  :class="[
                    line.statusColor,
                    { 'animate-pulse': line.status === 'connecting' },
                  ]"
                  :title="line.statusLabel"
                  data-testid="phone-widget-line-status-dot"
                />
                <i
                  class="shrink-0 text-xs"
                  :class="
                    line.isWhatsapp
                      ? 'i-ri-whatsapp-fill text-n-teal-9'
                      : 'i-ri-phone-fill text-n-slate-11'
                  "
                  aria-hidden="true"
                />
                <span
                  class="min-w-0 flex-1 truncate text-xs font-medium text-n-slate-12"
                  :title="
                    line.phoneNumber &&
                    !String(line.name || '').includes(line.phoneNumber)
                      ? `${line.name} (${line.phoneNumber})`
                      : line.name
                  "
                  data-testid="phone-widget-line-name"
                >
                  {{ line.name }}
                </span>
                <span class="sr-only" data-testid="phone-widget-line-status">
                  {{ line.statusLabel }}
                </span>
              </div>
              <div class="flex shrink-0 items-center gap-1">
                <span
                  v-if="line.providerLabel"
                  class="max-w-[5.5rem] truncate rounded bg-n-alpha-2 px-1.5 py-0.5 text-[10px] leading-none font-medium text-n-slate-11"
                  :title="line.providerLabel"
                  data-testid="phone-widget-line-provider"
                >
                  {{ line.providerLabel }}
                </span>
                <span
                  v-if="String(selectedInboxId) === String(line.id)"
                  class="inline-flex size-4 shrink-0 items-center justify-center rounded-full bg-n-teal-9/15 text-n-teal-11"
                  :title="selectedLineLabel"
                  data-testid="phone-widget-line-selected-badge"
                >
                  <i class="i-lucide-check text-[10px]" aria-hidden="true" />
                  <span class="sr-only">{{ selectedLineLabel }}</span>
                </span>
                <button
                  v-if="line.canReconnect"
                  type="button"
                  class="inline-flex size-5 shrink-0 items-center justify-center rounded bg-n-alpha-2 text-n-teal-11 hover:bg-n-teal-3 transition-colors"
                  :title="
                    line.movesHere
                      ? t('PHONE_WIDGET.MOVE_HERE')
                      : t('PHONE_WIDGET.REFRESH_CONNECTION')
                  "
                  :aria-label="
                    line.movesHere
                      ? t('PHONE_WIDGET.MOVE_HERE')
                      : t('PHONE_WIDGET.REFRESH_CONNECTION')
                  "
                  data-testid="phone-widget-line-reconnect"
                  @click.stop="reconnect(line.session)"
                >
                  <i
                    class="text-[11px]"
                    :class="
                      line.movesHere
                        ? 'i-lucide-monitor-down'
                        : 'i-lucide-refresh-cw'
                    "
                  />
                </button>
              </div>
            </div>
          </div>
          <div
            v-if="channelCapacityLabel"
            class="mb-2 flex items-center justify-between rounded-md px-2.5 py-1 text-xs font-medium"
            :class="
              channelCapacity?.outbound_available === false
                ? 'bg-n-ruby-3 text-n-ruby-11'
                : 'bg-n-alpha-2 text-n-slate-11'
            "
            data-testid="phone-widget-channel-capacity"
          >
            <span class="truncate">{{ channelCapacityLabel }}</span>
          </div>
          <div class="flex items-center gap-2">
            <Input
              id="phone-widget-number"
              v-model="phone"
              type="tel"
              inputmode="tel"
              autocomplete="off"
              class="min-w-0 flex-1"
              :placeholder="t('PHONE_WIDGET.NUMBER_PLACEHOLDER')"
              :aria-label="t('PHONE_WIDGET.NUMBER_PLACEHOLDER')"
              @paste="pasteNumber"
              @enter="dialOnEnter"
            />
            <VoiceCallButton
              v-if="canDial && selectedInbox"
              ref="callButton"
              :phone="dialNumber"
              :inbox-id="selectedInbox.id"
              :disabled="hasCall"
              :tooltip-label="t('PHONE_WIDGET.CALL')"
              :aria-label="t('PHONE_WIDGET.CALL')"
              icon="i-ph-phone-bold"
              size="md"
              teal
              class="shrink-0 !rounded-full shadow-sm"
              @call-initiated="isExpanded = false"
            />
            <Button
              v-else
              type="button"
              disabled
              variant="solid"
              color="slate"
              size="md"
              icon="i-ph-phone-bold"
              class="shrink-0 !rounded-full"
              :aria-label="t('PHONE_WIDGET.CALL')"
              :title="t('PHONE_WIDGET.CALL')"
            />
          </div>
          <div
            v-if="isExpanded"
            class="mt-4 border-t border-n-weak pt-4"
            data-testid="phone-widget-expanded"
          >
            <div class="grid grid-cols-3 gap-2">
              <Button
                v-for="key in dialKeys"
                :key="key"
                type="button"
                variant="outline"
                color="slate"
                size="lg"
                class="w-full"
                :aria-label="key"
                :data-testid="`phone-key-${key}`"
                @click="appendKey(key)"
              >
                <span class="text-lg font-medium">{{ key }}</span>
              </Button>
              <Button
                type="button"
                variant="outline"
                color="slate"
                size="lg"
                class="w-full !text-lg"
                label="+"
                :aria-label="t('PHONE_WIDGET.ADD_PLUS')"
                data-testid="phone-widget-plus"
                @click="appendPlus"
              />
              <Button
                type="button"
                variant="outline"
                color="slate"
                size="lg"
                class="w-full !text-lg"
                :label="String(0)"
                data-testid="phone-key-0"
                @click="appendKey('0')"
              />
              <Button
                type="button"
                variant="outline"
                color="slate"
                size="lg"
                class="w-full"
                icon="i-lucide-delete"
                :aria-label="t('PHONE_WIDGET.DELETE_DIGIT')"
                :title="t('PHONE_WIDGET.DELETE_DIGIT')"
                data-testid="phone-widget-delete"
                @click="removeLastKey"
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
