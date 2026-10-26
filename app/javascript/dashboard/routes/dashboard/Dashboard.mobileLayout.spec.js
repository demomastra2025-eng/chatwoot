import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

import wootConstants from 'dashboard/constants/globals';

const { CONDENSED, EXPANDED } = wootConstants.LAYOUT_TYPES;

// One shared settings object and one shared writer, as the real composable
// returns the same per-user store to every caller.
const ui = vi.hoisted(() => {
  const state = { uiSettings: null };
  // mockReset in the vitest config restores this original implementation.
  state.updateUISettings = vi.fn(settings => {
    state.uiSettings.value = { ...state.uiSettings.value, ...settings };
  });
  return state;
});
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ui,
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: ref(1) }),
}));
vi.mock('dashboard/stores/whatsappCalls', () => ({
  useWhatsappCallsStore: () => ({
    hasActiveCall: false,
    hasIncomingCall: false,
  }),
}));
vi.mock('next/sidebar/Sidebar.vue', () => ({
  default: { name: 'NextSidebar', template: '<aside />' },
}));
vi.mock('dashboard/components/widgets/modal/WootKeyShortcutModal.vue', () => ({
  default: { name: 'WootKeyShortcutModal', template: '<div />' },
}));
vi.mock('dashboard/components/app/AddAccountModal.vue', () => ({
  default: { name: 'AddAccountModal', template: '<div />' },
}));
vi.mock('dashboard/components-next/sidebar/MobileSidebarLauncher.vue', () => ({
  default: { name: 'MobileSidebarLauncher', template: '<div />' },
}));
vi.mock('./commands/commandbar.vue', () => ({
  __esModule: true,
  default: { name: 'CommandBar', template: '<div />' },
}));
vi.mock('dashboard/components/widgets/FloatingCallWidget.vue', () => ({
  __esModule: true,
  default: { name: 'FloatingCallWidget', template: '<div />' },
}));
vi.mock('dashboard/components/widgets/PhoneWidget.vue', () => ({
  __esModule: true,
  default: { name: 'PhoneWidget', template: '<div />' },
}));
vi.mock('dashboard/components/widgets/WhatsappCallWidget.vue', () => ({
  __esModule: true,
  default: { name: 'WhatsappCallWidget', template: '<div />' },
}));

import Dashboard from './Dashboard.vue';

ui.uiSettings = ref({});
const { uiSettings, updateUISettings } = ui;

const PHONE_WIDTH = 390;
const DESKTOP_WIDTH = 1440;

const setWindowWidth = width => {
  Object.defineProperty(window, 'innerWidth', {
    configurable: true,
    writable: true,
    value: width,
  });
};

const mountDashboard = () =>
  mount(Dashboard, {
    global: {
      mocks: { $route: { name: 'home' } },
      stubs: { 'router-view': true },
    },
  });

describe('Dashboard conversation layout on a phone', () => {
  const originalWidth = window.innerWidth;
  const givenStoredSettings = settings => {
    uiSettings.value = settings;
  };

  beforeEach(() => {
    setActivePinia(createPinia());
    updateUISettings.mockClear();
    uiSettings.value = {};
  });

  afterEach(() => {
    setWindowWidth(originalWidth);
  });

  it('applies the expanded layout on load when a desktop session left it condensed', async () => {
    // The deep link /conversations/:id opened in Safari: stored layout is the desktop one.
    setWindowWidth(PHONE_WIDTH);
    givenStoredSettings({
      conversation_display_type: CONDENSED,
      previously_used_conversation_display_type: CONDENSED,
    });

    mountDashboard();
    await flushPromises();

    expect(updateUISettings).toHaveBeenCalledTimes(1);
    expect(updateUISettings).toHaveBeenCalledWith({
      conversation_display_type: EXPANDED,
    });
    expect(uiSettings.value.conversation_display_type).toBe(EXPANDED);
    // The layout the person picked on desktop is kept for the way back.
    expect(uiSettings.value.previously_used_conversation_display_type).toBe(
      CONDENSED
    );
  });

  it('applies the expanded layout on load when no layout was ever stored', async () => {
    setWindowWidth(PHONE_WIDTH);

    mountDashboard();
    await flushPromises();

    expect(updateUISettings).toHaveBeenCalledWith({
      conversation_display_type: EXPANDED,
    });
  });

  it('writes nothing on a phone that already has the expanded layout', async () => {
    setWindowWidth(PHONE_WIDTH);
    givenStoredSettings({ conversation_display_type: EXPANDED });

    mountDashboard();
    await flushPromises();

    expect(updateUISettings).not.toHaveBeenCalled();
  });

  it('keeps the layout watcher immediate so a phone does not wait for a resize', () => {
    expect(Dashboard.watch.isSmallScreen.immediate).toBe(true);
  });

  it('switches to the expanded layout when a desktop window shrinks to a phone width', () => {
    setWindowWidth(PHONE_WIDTH);
    const context = {
      uiSettings: { conversation_display_type: CONDENSED },
      previouslyUsedDisplayType: CONDENSED,
      updateUISettings: vi.fn(),
    };

    Dashboard.watch.isSmallScreen.handler.call(context);

    expect(context.updateUISettings).toHaveBeenCalledWith({
      conversation_display_type: EXPANDED,
    });
  });

  it('gives a phone window that grows back to a desktop width its picked layout', () => {
    setWindowWidth(DESKTOP_WIDTH);
    const context = {
      uiSettings: { conversation_display_type: EXPANDED },
      previouslyUsedDisplayType: CONDENSED,
      updateUISettings: vi.fn(),
    };

    Dashboard.watch.isSmallScreen.handler.call(context);

    expect(context.updateUISettings).toHaveBeenCalledWith({
      conversation_display_type: CONDENSED,
    });
  });
});

describe('Dashboard conversation layout on a desktop', () => {
  const originalWidth = window.innerWidth;
  beforeEach(() => {
    setActivePinia(createPinia());
    updateUISettings.mockClear();
    uiSettings.value = {};
    setWindowWidth(DESKTOP_WIDTH);
  });

  afterEach(() => {
    setWindowWidth(originalWidth);
  });

  it('restores the layout the person picked after a phone forced the expanded one', async () => {
    uiSettings.value = {
      conversation_display_type: EXPANDED,
      previously_used_conversation_display_type: CONDENSED,
    };

    mountDashboard();
    await flushPromises();

    expect(updateUISettings).toHaveBeenCalledWith({
      conversation_display_type: CONDENSED,
    });
  });

  it('falls back to the condensed layout when the person never picked one', async () => {
    // A phone wrote expanded for a person who never touched the layout toggle.
    uiSettings.value = { conversation_display_type: EXPANDED };

    mountDashboard();
    await flushPromises();

    expect(updateUISettings).toHaveBeenCalledWith({
      conversation_display_type: CONDENSED,
    });
  });

  it('keeps an expanded layout the person picked on desktop', async () => {
    uiSettings.value = {
      conversation_display_type: EXPANDED,
      previously_used_conversation_display_type: EXPANDED,
    };

    mountDashboard();
    await flushPromises();

    expect(updateUISettings).not.toHaveBeenCalled();
  });

  it('writes nothing for a person who never stored a layout', async () => {
    mountDashboard();
    await flushPromises();

    expect(updateUISettings).not.toHaveBeenCalled();
  });
});
