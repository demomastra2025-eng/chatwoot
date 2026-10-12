import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import {
  startFaviconBlinking,
  stopFaviconBlinking,
} from 'dashboard/helper/AudioAlerts/faviconHelper';

// A ringing call must not depend on sound alone (the computer may be muted):
// while one rings in this tab it also shows an operating-system notification
// when the tab is not in front, and blinks the tab title and, in a hidden
// tab, the favicon. The browser cannot read the system volume, so none of
// this looks at the ringtone settings.
const BLINK_INTERVAL = 1000;
const TITLE_MARK = '📞 ';
const FAVICON_HOLDER = 'incoming-call';

const notificationApi = () =>
  typeof window !== 'undefined' && 'Notification' in window
    ? window.Notification
    : null;
const readPermission = () => notificationApi()?.permission || 'unsupported';
const operatorMayMissTab = () =>
  document.visibilityState !== 'visible' || !document.hasFocus();

const notificationPermission = ref(readPermission());
// Every reporting component by source id, like the ringtone: the call list
// that takes over a source must not be silenced by the old one unmounting.
const sources = new Map();
const notifications = new Map();
let listening = false;
let titleTimer = null;
let alertTitle = '';
let realTitle = '';

const startTitleBlink = title => {
  if (titleTimer) return;

  alertTitle = title;
  realTitle = document.title;
  document.title = alertTitle;
  titleTimer = setInterval(() => {
    // A stop without a holder (the socket dropped) also ends the call blink.
    if (document.visibilityState === 'hidden') {
      startFaviconBlinking(FAVICON_HOLDER);
    }
    if (document.title === alertTitle) {
      document.title = realTitle;
      return;
    }
    // The app may have changed the title meanwhile (route, unread counter).
    realTitle = document.title;
    document.title = alertTitle;
  }, BLINK_INTERVAL);
};

const stopTitleBlink = () => {
  if (!titleTimer) return;

  clearInterval(titleTimer);
  titleTimer = null;
  if (document.title === alertTitle) document.title = realTitle;
};

const closeNotification = key => {
  const entry = notifications.get(key);
  notifications.delete(key);
  try {
    entry?.notification?.close();
  } catch {
    // Already gone.
  }
};

const showNotification = (key, call, title) => {
  // A dismissed or failed notification stays in the map so that it is not
  // shown again for the same call.
  const entry = { body: call.body, notification: null, dismissed: false };
  notifications.set(key, entry);
  try {
    const Api = notificationApi();
    const notification = new Api(title, {
      body: call.body,
      tag: key,
      requireInteraction: true,
    });
    notification.onclick = () => {
      window.focus();
      notification.close();
    };
    notification.onclose = () => {
      entry.dismissed = true;
    };
    entry.notification = notification;
  } catch {
    entry.dismissed = true;
  }
};

const syncNotifications = (ringing, title) => {
  const canNotify = operatorMayMissTab() && readPermission() === 'granted';

  [...notifications.keys()].forEach(key => {
    if (!canNotify || !ringing.has(key)) closeNotification(key);
  });
  if (!canNotify) return;

  ringing.forEach((call, key) => {
    const entry = notifications.get(key);
    if (entry?.dismissed || entry?.body === call.body) return;

    // The tag makes a changed body replace the shown notification.
    closeNotification(key);
    showNotification(key, call, title);
  });
};

const syncAttention = () => {
  const ringing = new Map();
  let title = '';
  sources.forEach(source => {
    source.calls.forEach(call => ringing.set(call.key, call));
    if (source.calls.length) title = title || source.title;
  });

  if (ringing.size) {
    startTitleBlink(`${TITLE_MARK}${title}`);
  } else {
    stopTitleBlink();
  }
  if (ringing.size && document.visibilityState === 'hidden') {
    startFaviconBlinking(FAVICON_HOLDER);
  } else {
    stopFaviconBlinking(FAVICON_HOLDER);
  }
  syncNotifications(ringing, title);
};

const onTabStateChange = () => {
  notificationPermission.value = readPermission();
  syncAttention();
};

const syncTabListeners = () => {
  if (sources.size && !listening) {
    document.addEventListener('visibilitychange', onTabStateChange);
    window.addEventListener('focus', onTabStateChange);
    window.addEventListener('blur', onTabStateChange);
    listening = true;
  } else if (!sources.size && listening) {
    document.removeEventListener('visibilitychange', onTabStateChange);
    window.removeEventListener('focus', onTabStateChange);
    window.removeEventListener('blur', onTabStateChange);
    listening = false;
  }
};

// `ringingCalls` is a ref to the calls that ring in this tab right now, each
// as { key, body }: a stable id of the call and the line shown to the employee
// (the caller and the line). Several calls and sources share one title blink.
export const useIncomingCallAttention = (sourceId, ringingCalls) => {
  const { t } = useI18n();
  const owner = Symbol(sourceId);

  watch(
    ringingCalls,
    calls => {
      sources.set(sourceId, {
        owner,
        title: t('CONVERSATION.VOICE_WIDGET.INCOMING_CALL'),
        calls: (calls || []).filter(Boolean).map(call => ({
          ...call,
          key: `incoming-call:${sourceId}:${call.key ?? ''}`,
        })),
      });
      syncTabListeners();
      syncAttention();
    },
    { immediate: true }
  );

  onUnmounted(() => {
    if (sources.get(sourceId)?.owner !== owner) return;

    sources.delete(sourceId);
    syncTabListeners();
    syncAttention();
  });
};

// The browser asks for the notification permission only after a click, so the
// phone offers a button while the answer is still open.
export const useCallNotificationPermission = () => {
  const refresh = () => {
    notificationPermission.value = readPermission();
  };

  onMounted(() => {
    refresh();
    window.addEventListener('focus', refresh);
  });
  onUnmounted(() => window.removeEventListener('focus', refresh));

  const canRequestCallNotifications = computed(
    () => notificationPermission.value === 'default'
  );
  const requestCallNotifications = async () => {
    try {
      await notificationApi()?.requestPermission();
    } catch {
      // The prompt could not be shown; the button stays.
    }
    refresh();
  };

  return { canRequestCallNotifications, requestCallNotifications };
};
