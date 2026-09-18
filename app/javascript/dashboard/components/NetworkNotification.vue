<script setup>
import { ref, computed, onBeforeUnmount, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useEmitter } from 'dashboard/composables/emitter';
import { useMapGetter } from 'dashboard/composables/store';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import {
  isAConversationRoute,
  isAInboxViewRoute,
  isNotificationRoute,
} from 'dashboard/helper/routeHelpers';
import {
  getWhatsappWebDisplayLabel,
  getWhatsappWebImportAlertKey,
  getWhatsappWebState,
  hasWhatsappWebImportInProgress,
  hasWhatsappWebNonOpenState,
  isWhatsappWebReconnecting,
  isWhatsappWebTransientState,
} from 'dashboard/helper/whatsappWeb';
import {
  getTelegramPersonalDisplayLabel,
  getTelegramPersonalImportAlertKey,
  hasTelegramPersonalImportInProgress,
  hasTelegramPersonalNonConnectedState,
  isTelegramPersonalReconnecting,
  isTelegramPersonalTransientState,
} from 'dashboard/helper/telegramPersonal';
import { useEventListener } from '@vueuse/core';

import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'next/icon/Icon.vue';

const { t } = useI18n();
const route = useRoute();
const inboxes = useMapGetter('inboxes/getInboxes');

const RECONNECTED_BANNER_TIMEOUT = 2000;
const CHANNEL_ALERT_TIMEOUT = 3000;

const showNotification = ref(!navigator.onLine);
const isDisconnected = ref(false);
const isReconnecting = ref(false);
const isReconnected = ref(false);
const channelConnectionAlerts = ref([]);
const persistentImportAlerts = ref([]);
const reportedChannelAlertKeys = ref([]);
const dismissedImportAlertKeys = ref([]);
let reconnectTimeout = null;
const channelAlertTimeouts = new Map();

const bannerText = computed(() => {
  if (isReconnecting.value) return t('NETWORK.NOTIFICATION.RECONNECTING');
  if (isReconnected.value) return t('NETWORK.NOTIFICATION.RECONNECT_SUCCESS');
  return t('NETWORK.NOTIFICATION.OFFLINE');
});

const iconName = computed(() => (isReconnected.value ? 'wifi' : 'wifi-off'));
const canRefresh = computed(
  () => !isReconnecting.value && !isReconnected.value
);
const hasVisibleNotifications = computed(() => {
  return (
    showNotification.value ||
    channelConnectionAlerts.value.length > 0 ||
    persistentImportAlerts.value.length > 0
  );
});

const alertToneClass = tone => {
  return tone === 'ruby'
    ? 'bg-n-ruby-4 dark:bg-n-ruby-10'
    : 'bg-n-amber-4 dark:bg-n-amber-8';
};

const alertTextClass = tone => {
  return tone === 'ruby' ? 'text-n-ruby-12' : 'text-n-amber-12';
};

const alertButtonClass = tone => {
  return tone === 'ruby'
    ? '!text-n-ruby-12'
    : '!text-n-amber-12 dark:!text-n-amber-9';
};

const alertButtonToneProps = tone => {
  return tone === 'ruby' ? { ruby: true } : { amber: true };
};

const alertIconClass = alert => {
  return [
    'size-4',
    alertTextClass(alert.tone),
    alert.spinning ? 'animate-spin' : '',
  ];
};

const buildWhatsappConnectionAlertDescriptor = inbox => {
  const reconnecting = isWhatsappWebReconnecting(inbox);
  const transient = isWhatsappWebTransientState(inbox);

  if (reconnecting) {
    return {
      tone: 'amber',
      icon: 'i-lucide-refresh-cw',
      spinning: true,
      message: t('NETWORK.NOTIFICATION.WHATSAPP_WEB_RECONNECTING', {
        inbox: getWhatsappWebDisplayLabel(inbox),
      }),
    };
  }

  if (transient) {
    return {
      tone: 'amber',
      icon: 'i-lucide-loader-circle',
      spinning: true,
      message: t('NETWORK.NOTIFICATION.WHATSAPP_WEB_NOT_OPEN', {
        inbox: getWhatsappWebDisplayLabel(inbox),
      }),
    };
  }

  return {
    tone: 'ruby',
    icon: 'i-lucide-triangle-alert',
    spinning: false,
    message: t('NETWORK.NOTIFICATION.WHATSAPP_WEB_DISCONNECTED', {
      inbox: getWhatsappWebDisplayLabel(inbox),
    }),
  };
};

const buildTelegramPersonalConnectionAlertDescriptor = inbox => {
  const reconnecting = isTelegramPersonalReconnecting(inbox);
  const transient = isTelegramPersonalTransientState(inbox);

  if (reconnecting) {
    return {
      tone: 'amber',
      icon: 'i-lucide-refresh-cw',
      spinning: true,
      message: t('NETWORK.NOTIFICATION.TELEGRAM_PERSONAL_RECONNECTING', {
        inbox: getTelegramPersonalDisplayLabel(inbox),
      }),
    };
  }

  if (transient) {
    return {
      tone: 'amber',
      icon: 'i-lucide-loader-circle',
      spinning: true,
      message: t('NETWORK.NOTIFICATION.TELEGRAM_PERSONAL_NOT_CONNECTED', {
        inbox: getTelegramPersonalDisplayLabel(inbox),
      }),
    };
  }

  return {
    tone: 'ruby',
    icon: 'i-lucide-triangle-alert',
    spinning: false,
    message: t('NETWORK.NOTIFICATION.TELEGRAM_PERSONAL_DISCONNECTED', {
      inbox: getTelegramPersonalDisplayLabel(inbox),
    }),
  };
};

const alertableWhatsappConnectionInboxes = computed(() => {
  return inboxes.value
    .filter(inbox => hasWhatsappWebNonOpenState(inbox))
    .map(inbox => {
      const state = getWhatsappWebState(inbox);
      const lifecycleState =
        state.status || inbox?.lifecycle_state || 'unknown';
      const connectionState =
        state.connection_state || inbox?.connection_state || 'unknown';

      return {
        key: `whatsapp:${inbox.id}:${lifecycleState}:${connectionState}`,
        ...buildWhatsappConnectionAlertDescriptor(inbox),
      };
    });
});

const alertableTelegramPersonalConnectionInboxes = computed(() => {
  return inboxes.value
    .filter(inbox => hasTelegramPersonalNonConnectedState(inbox))
    .map(inbox => {
      const state = inbox.runtime_state || {};
      const lifecycleState = state.lifecycle_state || inbox?.lifecycle_state;
      const connectionState =
        state.connection_state || inbox?.connection_state || 'unknown';

      return {
        key: `telegram-personal:${inbox.id}:${lifecycleState}:${connectionState}`,
        ...buildTelegramPersonalConnectionAlertDescriptor(inbox),
      };
    });
});

const allChannelConnectionAlerts = computed(() => {
  return [
    ...alertableWhatsappConnectionInboxes.value,
    ...alertableTelegramPersonalConnectionInboxes.value,
  ];
});

const alertableImportInboxes = computed(() => {
  return inboxes.value.flatMap(inbox => {
    if (hasWhatsappWebImportInProgress(inbox)) {
      return [
        {
          key: getWhatsappWebImportAlertKey(inbox),
          tone: 'amber',
          icon: 'i-lucide-download',
          spinning: true,
          message: t('NETWORK.NOTIFICATION.WHATSAPP_WEB_IMPORT_IN_PROGRESS', {
            inbox: getWhatsappWebDisplayLabel(inbox),
          }),
        },
      ];
    }

    if (hasTelegramPersonalImportInProgress(inbox)) {
      return [
        {
          key: getTelegramPersonalImportAlertKey(inbox),
          tone: 'amber',
          icon: 'i-lucide-download',
          spinning: true,
          message: t(
            'NETWORK.NOTIFICATION.TELEGRAM_PERSONAL_IMPORT_IN_PROGRESS',
            {
              inbox: getTelegramPersonalDisplayLabel(inbox),
            }
          ),
        },
      ];
    }

    return [];
  });
});

const refreshPage = () => {
  window.location.reload();
};

const closeNotification = () => {
  showNotification.value = false;
  isReconnected.value = false;
  clearTimeout(reconnectTimeout);
};

const clearChannelAlertTimeout = key => {
  const timeoutId = channelAlertTimeouts.get(key);
  if (!timeoutId) {
    return;
  }

  clearTimeout(timeoutId);
  channelAlertTimeouts.delete(key);
};

const dismissChannelAlert = key => {
  clearChannelAlertTimeout(key);
  channelConnectionAlerts.value = channelConnectionAlerts.value.filter(
    alert => alert.key !== key
  );
};

const scheduleChannelAlertDismissal = key => {
  clearChannelAlertTimeout(key);
  const timeoutId = window.setTimeout(() => {
    dismissChannelAlert(key);
  }, CHANNEL_ALERT_TIMEOUT);
  channelAlertTimeouts.set(key, timeoutId);
};

const showChannelAlert = alert => {
  channelConnectionAlerts.value = [
    ...channelConnectionAlerts.value.filter(
      existingAlert => existingAlert.key !== alert.key
    ),
    alert,
  ];
  scheduleChannelAlertDismissal(alert.key);
};

const dismissImportAlert = key => {
  dismissedImportAlertKeys.value = [...dismissedImportAlertKeys.value, key];
  persistentImportAlerts.value = persistentImportAlerts.value.filter(
    alert => alert.key !== key
  );
};

const showPersistentImportAlert = alert => {
  persistentImportAlerts.value = [
    ...persistentImportAlerts.value.filter(
      existingAlert => existingAlert.key !== alert.key
    ),
    alert,
  ];
};

const isImportAlertVisible = key => {
  return persistentImportAlerts.value.some(alert => alert.key === key);
};

const isInAnyOfTheRoutes = routeName => {
  return (
    isAConversationRoute(routeName, true) ||
    isAInboxViewRoute(routeName, true) ||
    isNotificationRoute(routeName, true)
  );
};

const updateWebsocketStatus = () => {
  isDisconnected.value = true;
  showNotification.value = true;
};

const handleReconnectionCompleted = () => {
  isDisconnected.value = false;
  isReconnecting.value = false;
  isReconnected.value = true;
  showNotification.value = true;
  reconnectTimeout = setTimeout(closeNotification, RECONNECTED_BANNER_TIMEOUT);
};

const handleReconnecting = () => {
  if (isInAnyOfTheRoutes(route.name)) {
    isReconnecting.value = true;
    isReconnected.value = false;
    showNotification.value = true;
  } else {
    handleReconnectionCompleted();
  }
};

const updateOnlineStatus = event => {
  if (event.type === 'offline') {
    showNotification.value = true;
  } else if (event.type === 'online' && !isDisconnected.value) {
    handleReconnectionCompleted();
  }
};

useEventListener('online', updateOnlineStatus);
useEventListener('offline', updateOnlineStatus);
useEmitter(BUS_EVENTS.WEBSOCKET_DISCONNECT, updateWebsocketStatus);
useEmitter(
  BUS_EVENTS.WEBSOCKET_RECONNECT_COMPLETED,
  handleReconnectionCompleted
);
useEmitter(BUS_EVENTS.WEBSOCKET_RECONNECT, handleReconnecting);

watch(
  allChannelConnectionAlerts,
  alerts => {
    const activeKeys = alerts.map(alert => alert.key);

    reportedChannelAlertKeys.value = reportedChannelAlertKeys.value.filter(
      key => activeKeys.includes(key)
    );

    channelConnectionAlerts.value = channelConnectionAlerts.value.filter(
      alert => {
        const isStillActive = activeKeys.includes(alert.key);

        if (!isStillActive) {
          clearChannelAlertTimeout(alert.key);
        }

        return isStillActive;
      }
    );

    alerts.forEach(alert => {
      if (reportedChannelAlertKeys.value.includes(alert.key)) {
        return;
      }

      reportedChannelAlertKeys.value = [
        ...reportedChannelAlertKeys.value,
        alert.key,
      ];
      showChannelAlert(alert);
    });
  },
  { immediate: true }
);

watch(
  alertableImportInboxes,
  alerts => {
    const activeKeys = alerts.map(alert => alert.key);

    dismissedImportAlertKeys.value = dismissedImportAlertKeys.value.filter(
      key => activeKeys.includes(key)
    );

    persistentImportAlerts.value = persistentImportAlerts.value.filter(alert =>
      activeKeys.includes(alert.key)
    );

    alerts.forEach(alert => {
      if (dismissedImportAlertKeys.value.includes(alert.key)) {
        return;
      }

      if (isImportAlertVisible(alert.key)) {
        return;
      }

      showPersistentImportAlert(alert);
    });
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  clearTimeout(reconnectTimeout);
  channelAlertTimeouts.forEach(timeoutId => clearTimeout(timeoutId));
  channelAlertTimeouts.clear();
});
</script>

<template>
  <div
    v-show="hasVisibleNotifications"
    class="fixed z-50 top-2 left-2 max-w-sm space-y-2"
  >
    <transition name="network-notification-fade">
      <div v-show="showNotification" class="group">
        <div
          class="relative flex items-center justify-between w-full px-2 py-1 bg-n-amber-4 dark:bg-n-amber-8 rounded-lg shadow-lg"
        >
          <fluent-icon :icon="iconName" class="text-n-amber-12" size="18" />
          <span class="px-2 text-xs font-medium tracking-wide text-n-amber-12">
            {{ bannerText }}
          </span>
          <Button
            v-if="canRefresh"
            ghost
            sm
            amber
            icon="i-lucide-refresh-ccw"
            :title="$t('NETWORK.BUTTON.REFRESH')"
            class="!text-n-amber-12 dark:!text-n-amber-9"
            @click="refreshPage"
          />

          <Button
            ghost
            sm
            amber
            icon="i-lucide-x"
            class="!text-n-amber-12 dark:!text-n-amber-9"
            @click="closeNotification"
          />
        </div>
      </div>
    </transition>

    <transition-group
      name="network-notification-fade"
      tag="div"
      class="space-y-2"
    >
      <div
        v-for="alert in channelConnectionAlerts"
        :key="alert.key"
        class="relative flex items-center justify-between w-full px-2 py-1 rounded-lg shadow-lg"
        :class="alertToneClass(alert.tone)"
      >
        <Icon :icon="alert.icon" :class="alertIconClass(alert)" />
        <span
          class="px-2 text-xs font-medium tracking-wide"
          :class="alertTextClass(alert.tone)"
        >
          {{ alert.message }}
        </span>
        <Button
          ghost
          sm
          v-bind="alertButtonToneProps(alert.tone)"
          icon="i-lucide-x"
          :class="alertButtonClass(alert.tone)"
          @click="dismissChannelAlert(alert.key)"
        />
      </div>

      <div
        v-for="alert in persistentImportAlerts"
        :key="alert.key"
        class="relative flex items-center justify-between w-full px-2 py-1 rounded-lg shadow-lg"
        :class="alertToneClass(alert.tone)"
      >
        <Icon :icon="alert.icon" :class="alertIconClass(alert)" />
        <span
          class="px-2 text-xs font-medium tracking-wide"
          :class="alertTextClass(alert.tone)"
        >
          {{ alert.message }}
        </span>
        <Button
          ghost
          sm
          v-bind="alertButtonToneProps(alert.tone)"
          icon="i-lucide-x"
          :class="alertButtonClass(alert.tone)"
          @click="dismissImportAlert(alert.key)"
        />
      </div>
    </transition-group>
  </div>
</template>
