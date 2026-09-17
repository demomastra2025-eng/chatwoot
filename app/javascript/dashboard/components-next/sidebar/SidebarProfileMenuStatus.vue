<script setup>
import { computed, h, onMounted, onUnmounted, ref } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import wootConstants from 'dashboard/constants/globals';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useImpersonation } from 'dashboard/composables/useImpersonation';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';

import {
  DropdownContainer,
  DropdownBody,
  DropdownSection,
  DropdownItem,
} from 'next/dropdown-menu/base';
import Icon from 'next/icon/Icon.vue';
import Button from 'next/button/Button.vue';
import ToggleSwitch from 'dashboard/components-next/switch/Switch.vue';

const { t } = useI18n();
const store = useStore();
const currentUserAvailability = useMapGetter('getCurrentUserAvailability');
const currentAccountId = useMapGetter('getCurrentAccountId');
const currentUserAutoOffline = useMapGetter('getCurrentUserAutoOffline');
const currentUserInboxes = useMapGetter('inboxes/getInboxes');

const { isImpersonating } = useImpersonation();

const { AVAILABILITY_STATUS_KEYS } = wootConstants;
const NATIVE_SIP_PROVIDERS = new Set([
  'asterisk_analog',
  'sipuni',
  'binotel',
  'beeline',
  'wazo',
]);
const SIP_STANDBY_REASON =
  'sip_profile_registration_lease_owned_by_another_tab';
const sipSessions = ref([]);
const connectingSipSessionKeys = ref(new Set());

const syncSipSessions = () => {
  sipSessions.value = Object.values(WebphoneClient.sessions).filter(session =>
    NATIVE_SIP_PROVIDERS.has(session?.provider)
  );
};

const hasSipTelephony = computed(() => sipSessions.value.length > 0);
const sipChannelName = session => {
  const inbox = (currentUserInboxes.value || []).find(
    item => String(item.id) === String(session.inboxId)
  );
  return (
    inbox?.name ||
    t('SIDEBAR.SIP_TELEPHONY.CHANNEL_FALLBACK', { id: session.inboxId })
  );
};
const sipStatus = session => {
  if (connectingSipSessionKeys.value.has(session.sessionKey)) {
    return 'connecting';
  }
  if (session.registered === true) return 'ready';
  if (session.reason === SIP_STANDBY_REASON) return 'standby';
  if (
    session.callingSupported === false ||
    /error|fail|timeout|auth|credential|password/i.test(session.reason || '')
  ) {
    return 'error';
  }
  return 'disconnected';
};
const sipStatusConfig = session => {
  const statuses = {
    ready: {
      label: t('SIDEBAR.SIP_TELEPHONY.STATUS.READY'),
      icon: 'i-lucide-circle-check',
      color: 'text-[#008573]',
    },
    connecting: {
      label: t('SIDEBAR.SIP_TELEPHONY.STATUS.CONNECTING'),
      icon: 'i-lucide-loader-circle',
      color: 'text-n-amber-12',
    },
    disconnected: {
      label: t('SIDEBAR.SIP_TELEPHONY.STATUS.DISCONNECTED'),
      icon: 'i-lucide-refresh-cw',
      color: 'text-[#ca244d]',
    },
    standby: {
      label: t('SIDEBAR.SIP_TELEPHONY.STATUS.ACTIVE_IN_ANOTHER_TAB'),
      icon: 'i-lucide-monitor',
      color: 'text-n-slate-11',
    },
    error: {
      label: t('SIDEBAR.SIP_TELEPHONY.STATUS.ERROR'),
      icon: 'i-lucide-refresh-cw',
      color: 'text-[#ca244d]',
    },
  };

  return statuses[sipStatus(session)];
};
const canReconnectSip = session =>
  ['disconnected', 'error'].includes(sipStatus(session));
const statusList = computed(() => {
  return [
    t('PROFILE_SETTINGS.FORM.AVAILABILITY.STATUS.ONLINE'),
    t('PROFILE_SETTINGS.FORM.AVAILABILITY.STATUS.BUSY'),
    t('PROFILE_SETTINGS.FORM.AVAILABILITY.STATUS.OFFLINE'),
  ];
});

const statusColors = ['bg-n-teal-9', 'bg-n-amber-9', 'bg-n-slate-9'];

const availabilityStatuses = computed(() => {
  return statusList.value.map((statusLabel, index) => ({
    label: statusLabel,
    value: AVAILABILITY_STATUS_KEYS[index],
    color: statusColors[index],
    icon: h('span', { class: [statusColors[index], 'size-[12px] rounded'] }),
    active: currentUserAvailability.value === AVAILABILITY_STATUS_KEYS[index],
  }));
});

const activeStatus = computed(() => {
  return availabilityStatuses.value.find(status => status.active);
});

const autoOfflineToggle = computed({
  get: () => currentUserAutoOffline.value,
  set: autoOffline => {
    store.dispatch('updateAutoOffline', {
      accountId: currentAccountId.value,
      autoOffline,
    });
  },
});

function changeAvailabilityStatus(availability) {
  if (isImpersonating.value) {
    useAlert(t('PROFILE_SETTINGS.FORM.AVAILABILITY.IMPERSONATING_ERROR'));
    return;
  }
  try {
    store.dispatch('updateAvailability', {
      availability,
      account_id: currentAccountId.value,
    });
  } catch (error) {
    useAlert(t('PROFILE_SETTINGS.FORM.AVAILABILITY.SET_AVAILABILITY_ERROR'));
  }
}

async function reconnectSip(session) {
  if (!canReconnectSip(session)) return;

  connectingSipSessionKeys.value = new Set([
    ...connectingSipSessionKeys.value,
    session.sessionKey,
  ]);
  try {
    await WebphoneClient.initializeDevice(session.inboxId, {
      native: true,
      provider: session.provider,
      sipProfileId: session.sipProfileId,
      sessionKey: session.sessionKey,
    });
  } catch {
    // Keep the current error state so the user can retry again.
  } finally {
    syncSipSessions();
    const nextConnectingKeys = new Set(connectingSipSessionKeys.value);
    nextConnectingKeys.delete(session.sessionKey);
    connectingSipSessionKeys.value = nextConnectingKeys;
  }
}

const handleSipSessionsChanged = () => syncSipSessions();

onMounted(async () => {
  WebphoneClient.addEventListener(
    'call:sessions-changed',
    handleSipSessionsChanged
  );
  syncSipSessions();

  try {
    await WebphoneClient.bootstrapIncomingSupport();
  } catch {
    // The indicator reflects any existing SIP session and remains retryable.
  } finally {
    syncSipSessions();
  }
});

onUnmounted(() => {
  WebphoneClient.removeEventListener(
    'call:sessions-changed',
    handleSipSessionsChanged
  );
});
</script>

<template>
  <DropdownSection class="[&>ul]:overflow-visible">
    <div class="grid gap-0">
      <DropdownItem preserve-open class="gap-1">
        <div class="flex-grow flex items-center gap-1 min-w-0">
          {{ $t('SIDEBAR.SET_YOUR_AVAILABILITY') }}
        </div>
        <DropdownContainer class="shrink-0">
          <template #trigger="{ toggle }">
            <Button
              size="sm"
              color="slate"
              variant="faded"
              icon="i-lucide-chevron-down"
              trailing-icon
              @click="toggle"
            >
              <div class="flex gap-1 items-center min-w-0 text-sm">
                <div class="p-1 flex-shrink-0">
                  <div class="size-2 rounded-sm" :class="activeStatus.color" />
                </div>
                <span class="truncate max-w-[7rem]">
                  {{ activeStatus.label }}
                </span>
              </div>
            </Button>
          </template>
          <DropdownBody class="min-w-32 z-20">
            <DropdownItem
              v-for="status in availabilityStatuses"
              :key="status.value"
              :label="status.label"
              :icon="status.icon"
              class="cursor-pointer"
              @click="changeAvailabilityStatus(status.value)"
            />
          </DropdownBody>
        </DropdownContainer>
      </DropdownItem>
      <DropdownItem
        v-for="session in hasSipTelephony ? sipSessions : []"
        :key="session.sessionKey"
        preserve-open
        data-testid="sip-telephony-status"
      >
        <div class="flex-grow min-w-0 truncate text-sm">
          {{
            $t('SIDEBAR.SIP_TELEPHONY.CHANNEL_LABEL', {
              name: sipChannelName(session),
            })
          }}
        </div>
        <button
          type="button"
          class="flex items-center justify-end shrink-0 gap-1 min-w-0 font-normal disabled:opacity-100"
          :class="[
            sipStatusConfig(session).color,
            { 'cursor-pointer': canReconnectSip(session) },
          ]"
          :disabled="!canReconnectSip(session)"
          :title="
            canReconnectSip(session)
              ? $t('SIDEBAR.SIP_TELEPHONY.RECONNECT')
              : sipStatusConfig(session).label
          "
          data-testid="sip-telephony-indicator"
          @click="reconnectSip(session)"
        >
          <span class="text-xs whitespace-nowrap">
            {{ sipStatusConfig(session).label }}
          </span>
          <Icon
            :icon="sipStatusConfig(session).icon"
            class="size-4"
            :class="{ 'animate-spin': sipStatus(session) === 'connecting' }"
          />
        </button>
      </DropdownItem>
      <DropdownItem preserve-open>
        <div class="flex-grow min-w-0">
          {{ $t('SIDEBAR.SET_AUTO_OFFLINE.TEXT') }}
          <Icon
            v-tooltip.top="$t('SIDEBAR.SET_AUTO_OFFLINE.INFO_SHORT')"
            icon="i-lucide-info"
            class="inline-block align-middle ms-1 size-4 text-n-slate-10"
          />
        </div>
        <ToggleSwitch v-model="autoOfflineToggle" />
      </DropdownItem>
    </div>
  </DropdownSection>
</template>
