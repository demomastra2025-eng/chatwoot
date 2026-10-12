import { mount } from '@vue/test-utils';
import { computed, defineComponent, nextTick, ref } from 'vue';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const testState = vi.hoisted(() => ({
  uiSettings: null,
  setSourceState: vi.fn(),
  removeSource: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key =>
      key === 'CONVERSATION.VOICE_WIDGET.INCOMING_CALL'
        ? 'Входящий звонок'
        : key,
  }),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: testState.uiSettings }),
}));

vi.mock('dashboard/helper/AudioAlerts/IncomingCallRingtone', () => ({
  default: {
    setSourceState: testState.setSourceState,
    removeSource: testState.removeSource,
  },
}));

// The real helper runs (the favicon in the page changes); the spies only
// record who asked for what.
vi.mock('dashboard/helper/AudioAlerts/faviconHelper', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    startFaviconBlinking: vi.fn(actual.startFaviconBlinking),
    stopFaviconBlinking: vi.fn(actual.stopFaviconBlinking),
  };
});

import {
  showBadgeOnFavicon,
  startFaviconBlinking,
  stopFaviconBlinking,
} from 'dashboard/helper/AudioAlerts/faviconHelper';
import { useIncomingCallRingtone } from './useIncomingCallRingtone';
import {
  useCallNotificationPermission,
  useIncomingCallAttention,
} from './useIncomingCallAttention';

class FakeNotification {
  static permission = 'granted';

  static instances = [];

  static failWith = null;

  static requestPermission = null;

  constructor(title, options) {
    if (FakeNotification.failWith) throw FakeNotification.failWith;

    this.title = title;
    this.options = options;
    this.close = vi.fn(() => this.onclose?.());
    FakeNotification.instances.push(this);
  }

  // The employee closes the notification himself.
  dismiss() {
    this.onclose?.();
  }
}

const ALERT_TITLE = '📞 Входящий звонок';
const FAVICON_PLAIN = '/favicon-16x16.png';
const FAVICON_BADGE = '/favicon-badge-16x16.png';
const originalVisibilityState = Object.getOwnPropertyDescriptor(
  document,
  'visibilityState'
);

let hasFocusSpy;
let windowFocusSpy;
let wrappers;

const setTabState = ({ visible = true, focused = true } = {}) => {
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    value: visible ? 'visible' : 'hidden',
  });
  hasFocusSpy.mockReturnValue(focused);
};
const leaveTab = () => {
  setTabState({ visible: false, focused: false });
  document.dispatchEvent(new Event('visibilitychange'));
};
const returnToTab = () => {
  setTabState({ visible: true, focused: true });
  document.dispatchEvent(new Event('visibilitychange'));
  window.dispatchEvent(new Event('focus'));
};
const faviconPath = () =>
  document.querySelector('.favicon').getAttribute('href');

const call = (key, body = 'Айгерим · Sipuni') => ({ key, body });
const mountComposable = useComposables => {
  const wrapper = mount(
    defineComponent({
      setup() {
        useComposables();
        return () => null;
      },
    })
  );
  wrappers.push(wrapper);
  return wrapper;
};
const mountAttention = (calls, source = 'voice') =>
  mountComposable(() => useIncomingCallAttention(source, calls));
const unmount = wrapper => {
  wrappers.splice(wrappers.indexOf(wrapper), 1);
  wrapper.unmount();
};
const lastNotification = () => FakeNotification.instances.at(-1);

describe('useIncomingCallAttention', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    wrappers = [];
    FakeNotification.permission = 'granted';
    FakeNotification.instances = [];
    FakeNotification.failWith = null;
    FakeNotification.requestPermission = vi.fn();
    vi.stubGlobal('Notification', FakeNotification);
    hasFocusSpy = vi.spyOn(document, 'hasFocus');
    windowFocusSpy = vi.spyOn(window, 'focus').mockImplementation(() => {});
    setTabState();
    document.head.innerHTML = `<link class="favicon" rel="icon" sizes="16x16" href="${FAVICON_PLAIN}">`;
    document.title = 'Чаты';
    testState.uiSettings = ref({});
    testState.setSourceState.mockReset();
    testState.removeSource.mockReset();
  });

  afterEach(() => {
    wrappers.forEach(wrapper => wrapper.unmount());
    stopFaviconBlinking();
    hasFocusSpy.mockRestore();
    windowFocusSpy.mockRestore();
    vi.unstubAllGlobals();
    if (originalVisibilityState) {
      Object.defineProperty(
        document,
        'visibilityState',
        originalVisibilityState
      );
    } else {
      delete document.visibilityState;
    }
    document.head.innerHTML = '';
    vi.useRealTimers();
  });

  describe('system notification', () => {
    it('shows one for a call that rings in a tab nobody looks at', () => {
      setTabState({ visible: false, focused: false });

      mountAttention(ref([call('sipuni:c1')]));

      expect(FakeNotification.instances).toHaveLength(1);
      expect(lastNotification().title).toBe('Входящий звонок');
      expect(lastNotification().options).toEqual({
        body: 'Айгерим · Sipuni',
        tag: 'incoming-call:voice:sipuni:c1',
        requireInteraction: true,
      });
    });

    it('waits while the employee looks at the tab and shows it once the tab is left', () => {
      mountAttention(ref([call('c1')]));
      expect(FakeNotification.instances).toHaveLength(0);

      leaveTab();

      expect(FakeNotification.instances).toHaveLength(1);
    });

    it('shows it when the tab is visible but another window has the focus', () => {
      mountAttention(ref([call('c1')]));

      setTabState({ visible: true, focused: false });
      window.dispatchEvent(new Event('blur'));

      expect(FakeNotification.instances).toHaveLength(1);
    });

    it('closes it when the employee comes back to the tab and shows a new one when he leaves again', () => {
      setTabState({ visible: false, focused: false });
      mountAttention(ref([call('c1')]));
      const first = lastNotification();

      returnToTab();
      expect(first.close).toHaveBeenCalledOnce();

      leaveTab();
      expect(FakeNotification.instances).toHaveLength(2);
    });

    it.each(['default', 'denied'])(
      'stays out of the way while the permission is %s',
      permission => {
        FakeNotification.permission = permission;
        setTabState({ visible: false, focused: false });

        mountAttention(ref([call('c1')]));

        expect(FakeNotification.instances).toHaveLength(0);
        expect(document.title).toBe(ALERT_TITLE);
      }
    );

    it('does nothing without the Notification API', () => {
      vi.unstubAllGlobals();
      expect('Notification' in window).toBe(false);
      setTabState({ visible: false, focused: false });

      expect(() => mountAttention(ref([call('c1')]))).not.toThrow();
      expect(document.title).toBe(ALERT_TITLE);
    });

    it('does not depend on the ringtone setting', () => {
      testState.uiSettings = ref({ voice_call_ringtone_enabled: false });
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1')]);

      mountComposable(() => {
        useIncomingCallRingtone(
          'voice',
          computed(() => ringing.value.length > 0)
        );
        useIncomingCallAttention('voice', ringing);
      });

      expect(testState.setSourceState).toHaveBeenLastCalledWith(
        'voice',
        expect.objectContaining({ active: false })
      );
      expect(FakeNotification.instances).toHaveLength(1);
    });

    it('closes it as soon as the call is answered, declined, taken by a colleague or ended', async () => {
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1'), call('c2')]);
      mountAttention(ringing);
      const [first, second] = FakeNotification.instances;

      ringing.value = [call('c2')];
      await nextTick();
      expect(first.close).toHaveBeenCalledOnce();
      expect(second.close).not.toHaveBeenCalled();

      ringing.value = [];
      await nextTick();
      expect(second.close).toHaveBeenCalledOnce();
      expect(FakeNotification.instances).toHaveLength(2);
    });

    it('closes every notification when the component unmounts', () => {
      setTabState({ visible: false, focused: false });
      const wrapper = mountAttention(ref([call('c1'), call('c2')]));

      unmount(wrapper);

      FakeNotification.instances.forEach(notification =>
        expect(notification.close).toHaveBeenCalledOnce()
      );
      expect(vi.getTimerCount()).toBe(0);
    });

    it('brings the tab to the front on click and closes the notification', () => {
      setTabState({ visible: false, focused: false });
      mountAttention(ref([call('c1')]));

      lastNotification().onclick();

      expect(windowFocusSpy).toHaveBeenCalledOnce();
      expect(lastNotification().close).toHaveBeenCalledOnce();
    });

    it('does not show it again for the same call after the employee closed it', async () => {
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1')]);
      mountAttention(ringing);

      lastNotification().dismiss();
      window.dispatchEvent(new Event('blur'));
      document.dispatchEvent(new Event('visibilitychange'));
      // Not even when the caller becomes known after he closed it.
      ringing.value = [call('c1', '+77070001003 · Sipuni')];
      await nextTick();
      expect(FakeNotification.instances).toHaveLength(1);

      ringing.value = [call('c1', '+77070001003 · Sipuni'), call('c2')];
      await nextTick();
      expect(FakeNotification.instances).toHaveLength(2);
      expect(lastNotification().options.tag).toBe('incoming-call:voice:c2');
    });

    it('replaces the notification of a call under the same tag when the caller becomes known', async () => {
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1', '+77070001003 · Sipuni')]);
      mountAttention(ringing);
      const [first] = FakeNotification.instances;

      ringing.value = [call('c1', 'Айгерим · Sipuni')];
      await nextTick();

      expect(first.close).toHaveBeenCalledOnce();
      expect(FakeNotification.instances).toHaveLength(2);
      expect(lastNotification().options).toMatchObject({
        body: 'Айгерим · Sipuni',
        tag: first.options.tag,
      });
    });

    it('does not show the same notification twice for an unchanged call', async () => {
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1')]);
      mountAttention(ringing);

      ringing.value = [call('c1')];
      await nextTick();
      window.dispatchEvent(new Event('blur'));

      expect(FakeNotification.instances).toHaveLength(1);
    });

    it('gives every ringing call its own notification', () => {
      setTabState({ visible: false, focused: false });

      mountAttention(ref([call('c1'), call('c2')]));
      mountAttention(ref([call('w1', 'Айдар · WhatsApp')]), 'whatsapp');

      expect(
        FakeNotification.instances.map(({ options }) => options.tag)
      ).toEqual([
        'incoming-call:voice:c1',
        'incoming-call:voice:c2',
        'incoming-call:whatsapp:w1',
      ]);
    });

    it('never throws when the browser refuses to show a notification', () => {
      FakeNotification.failWith = new TypeError('Illegal constructor');
      setTabState({ visible: false, focused: false });

      expect(() => mountAttention(ref([call('c1')]))).not.toThrow();
      window.dispatchEvent(new Event('blur'));
      expect(document.title).toBe(ALERT_TITLE);
    });

    it('keeps the notification when another component takes over the source', () => {
      setTabState({ visible: false, focused: false });
      const standalone = mountAttention(ref([call('c1')]));
      const embedded = mountAttention(ref([call('c1')]));
      const [notification] = FakeNotification.instances;

      unmount(standalone);

      expect(notification.close).not.toHaveBeenCalled();
      unmount(embedded);
      expect(notification.close).toHaveBeenCalledOnce();
    });
  });

  describe('tab title', () => {
    it('alternates the alert and the real title every second and restores it afterwards', async () => {
      const ringing = ref([call('c1')]);
      mountAttention(ringing);
      expect(document.title).toBe(ALERT_TITLE);

      vi.advanceTimersByTime(1000);
      expect(document.title).toBe('Чаты');
      vi.advanceTimersByTime(1000);
      expect(document.title).toBe(ALERT_TITLE);

      ringing.value = [];
      await nextTick();
      expect(document.title).toBe('Чаты');
      expect(vi.getTimerCount()).toBe(0);
      vi.advanceTimersByTime(3000);
      expect(document.title).toBe('Чаты');
    });

    it('leaves the title alone while nothing rings', () => {
      mountAttention(ref([]));

      expect(document.title).toBe('Чаты');
      expect(vi.getTimerCount()).toBe(0);
    });

    it('starts when a call appears later', async () => {
      const ringing = ref([]);
      mountAttention(ringing);

      ringing.value = [call('c1')];
      await nextTick();

      expect(document.title).toBe(ALERT_TITLE);
      expect(vi.getTimerCount()).toBe(1);
    });

    it('restores the latest title when the app changed it between blinks', async () => {
      const ringing = ref([call('c1')]);
      mountAttention(ringing);
      vi.advanceTimersByTime(1000);
      expect(document.title).toBe('Чаты');

      document.title = '(2) Чаты';
      vi.advanceTimersByTime(1000);
      expect(document.title).toBe(ALERT_TITLE);
      ringing.value = [];
      await nextTick();

      expect(document.title).toBe('(2) Чаты');
    });

    it('does not overwrite a title the app set while the alert was shown', async () => {
      const ringing = ref([call('c1')]);
      mountAttention(ringing);
      expect(document.title).toBe(ALERT_TITLE);

      document.title = 'Контакты';
      ringing.value = [];
      await nextTick();
      expect(document.title).toBe('Контакты');
    });

    it('keeps blinking with the latest title after the app changed it during the alert', () => {
      mountAttention(ref([call('c1')]));

      document.title = 'Контакты';
      vi.advanceTimersByTime(1000);
      expect(document.title).toBe(ALERT_TITLE);
      vi.advanceTimersByTime(1000);
      expect(document.title).toBe('Контакты');
    });

    it('blinks once for several calls and sources and stops after the last one', async () => {
      const voice = ref([call('c1'), call('c2')]);
      const whatsapp = ref([call('w1')]);
      mountAttention(voice);
      const whatsappWrapper = mountAttention(whatsapp, 'whatsapp');
      expect(vi.getTimerCount()).toBe(1);

      voice.value = [call('c2')];
      await nextTick();
      voice.value = [];
      await nextTick();
      expect(document.title).toBe(ALERT_TITLE);
      expect(vi.getTimerCount()).toBe(1);

      unmount(whatsappWrapper);
      expect(document.title).toBe('Чаты');
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe('favicon', () => {
    it('blinks the favicon while the call rings in a hidden tab and stops with the call', async () => {
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1')]);
      mountAttention(ringing);

      expect(startFaviconBlinking).toHaveBeenCalledWith('incoming-call');
      expect(faviconPath()).toBe(FAVICON_BADGE);
      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe(FAVICON_PLAIN);

      ringing.value = [];
      await nextTick();
      expect(faviconPath()).toBe(FAVICON_PLAIN);
      expect(vi.getTimerCount()).toBe(0);
    });

    it('does not touch the favicon while the tab is visible', () => {
      mountAttention(ref([call('c1')]));
      vi.advanceTimersByTime(3000);

      expect(startFaviconBlinking).not.toHaveBeenCalled();
      expect(faviconPath()).toBe(FAVICON_PLAIN);
    });

    it('starts the favicon blink again after a stop without a holder, such as a dropped socket', () => {
      setTabState({ visible: false, focused: false });
      mountAttention(ref([call('c1')]));
      expect(vi.getTimerCount()).toBe(2);

      stopFaviconBlinking();
      expect(faviconPath()).toBe(FAVICON_PLAIN);
      expect(vi.getTimerCount()).toBe(1);

      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe(FAVICON_BADGE);
      expect(vi.getTimerCount()).toBe(2);
    });

    it('brings an unread badge back when the call ends in a hidden tab', async () => {
      setTabState({ visible: false, focused: false });
      showBadgeOnFavicon();
      const ringing = ref([call('c1')]);
      mountAttention(ringing);
      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe(FAVICON_PLAIN);

      ringing.value = [];
      await nextTick();

      expect(faviconPath()).toBe(FAVICON_BADGE);
      expect(vi.getTimerCount()).toBe(0);
    });

    it('does not remove an unread badge when no call rings', async () => {
      const ringing = ref([call('c1')]);
      mountAttention(ringing);
      showBadgeOnFavicon();

      ringing.value = [];
      await nextTick();
      window.dispatchEvent(new Event('blur'));

      expect(faviconPath()).toBe(FAVICON_BADGE);
    });

    it('starts blinking when the tab gets hidden during the call and stops when it is shown', () => {
      mountAttention(ref([call('c1')]));
      expect(faviconPath()).toBe(FAVICON_PLAIN);

      leaveTab();
      expect(faviconPath()).toBe(FAVICON_BADGE);

      returnToTab();
      expect(faviconPath()).toBe(FAVICON_PLAIN);
      expect(vi.getTimerCount()).toBe(1);

      leaveTab();
      expect(faviconPath()).toBe(FAVICON_BADGE);
    });

    it('leaves a notification blink that started before the call running when the call ends', async () => {
      setTabState({ visible: false, focused: false });
      startFaviconBlinking();
      const ringing = ref([call('c1')]);
      mountAttention(ringing);

      ringing.value = [];
      await nextTick();

      expect(vi.getTimerCount()).toBe(1);
      expect(faviconPath()).toBe(FAVICON_BADGE);
      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe(FAVICON_PLAIN);
      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe(FAVICON_BADGE);
    });

    it('leaves a notification blink that joined the call blink running when the call ends', async () => {
      setTabState({ visible: false, focused: false });
      const ringing = ref([call('c1')]);
      mountAttention(ringing);
      startFaviconBlinking();

      ringing.value = [];
      await nextTick();

      expect(vi.getTimerCount()).toBe(1);
      expect(faviconPath()).toBe(FAVICON_BADGE);
    });
  });

  describe('useCallNotificationPermission', () => {
    const mountPermission = () => {
      let api;
      mountComposable(() => {
        api = useCallNotificationPermission();
      });
      return api;
    };

    it.each([
      ['default', true],
      ['granted', false],
      ['denied', false],
    ])('offers the request for the permission %s: %s', (state, offered) => {
      FakeNotification.permission = state;

      const { canRequestCallNotifications } = mountPermission();

      expect(canRequestCallNotifications.value).toBe(offered);
    });

    it('offers nothing without the Notification API', () => {
      vi.unstubAllGlobals();

      const { canRequestCallNotifications } = mountPermission();

      expect(canRequestCallNotifications.value).toBe(false);
    });

    it('asks only on request and follows the answer', async () => {
      FakeNotification.permission = 'default';
      FakeNotification.requestPermission.mockImplementation(async () => {
        FakeNotification.permission = 'granted';
        return 'granted';
      });
      const { canRequestCallNotifications, requestCallNotifications } =
        mountPermission();
      expect(FakeNotification.requestPermission).not.toHaveBeenCalled();

      await requestCallNotifications();

      expect(FakeNotification.requestPermission).toHaveBeenCalledOnce();
      expect(canRequestCallNotifications.value).toBe(false);
    });

    it('stops offering the request after a refusal', async () => {
      FakeNotification.permission = 'default';
      FakeNotification.requestPermission.mockImplementation(async () => {
        FakeNotification.permission = 'denied';
        return 'denied';
      });
      const { canRequestCallNotifications, requestCallNotifications } =
        mountPermission();

      await requestCallNotifications();

      expect(canRequestCallNotifications.value).toBe(false);
    });

    it('keeps offering the request when the prompt is closed without an answer', async () => {
      FakeNotification.permission = 'default';
      FakeNotification.requestPermission.mockResolvedValue('default');
      const { canRequestCallNotifications, requestCallNotifications } =
        mountPermission();

      await requestCallNotifications();

      expect(canRequestCallNotifications.value).toBe(true);
    });

    it('never throws when the request fails', async () => {
      FakeNotification.permission = 'default';
      FakeNotification.requestPermission.mockRejectedValue(new Error('no'));
      const { requestCallNotifications } = mountPermission();

      await expect(requestCallNotifications()).resolves.toBeUndefined();
    });

    it('follows a change made in the browser settings when the tab gets the focus back', () => {
      FakeNotification.permission = 'default';
      const { canRequestCallNotifications } = mountPermission();
      expect(canRequestCallNotifications.value).toBe(true);

      FakeNotification.permission = 'granted';
      window.dispatchEvent(new Event('focus'));

      expect(canRequestCallNotifications.value).toBe(false);
    });
  });
});
