import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { useCallsStore } from 'dashboard/stores/calls';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import SidebarPhoneToggle from './SidebarPhoneToggle.vue';

const { settingsState, accountState } = vi.hoisted(() => ({
  settingsState: { settings: null, update: vi.fn() },
  accountState: { id: null },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: settingsState.settings,
    updateUISettings: settingsState.update,
  }),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => accountState.id,
}));
vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: { endClientCall: vi.fn() },
}));

const mountToggle = (props = {}) => mount(SidebarPhoneToggle, { props });
const toggleButton = wrapper =>
  wrapper.get('[data-testid="sidebar-phone-toggle"]');

describe('SidebarPhoneToggle', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    accountState.id = ref(1);
    settingsState.settings = ref({});
    settingsState.update.mockReset().mockImplementation(next => {
      settingsState.settings.value = {
        ...settingsState.settings.value,
        ...next,
      };
    });
    usePhoneWidgetStore().publishSipState({
      available: true,
      status: 'ready',
    });
  });

  it.each([
    ['ready', 'bg-n-teal-9'],
    ['ownerTab', 'bg-n-teal-9'],
    ['connecting', 'bg-n-amber-9'],
    ['disconnected', 'bg-n-slate-9'],
    ['error', 'bg-n-ruby-9'],
  ])('shows the %s SIP state like the phone header', (status, colour) => {
    usePhoneWidgetStore().publishSipState({ available: true, status });
    const wrapper = mountToggle();

    expect(toggleButton(wrapper).attributes('data-status')).toBe(status);
    expect(
      wrapper.get('[data-testid="sidebar-phone-toggle-status"]').classes()
    ).toContain(colour);
  });

  it('follows SIP state changes published by the widget', async () => {
    const wrapper = mountToggle();
    expect(toggleButton(wrapper).attributes('data-status')).toBe('ready');

    usePhoneWidgetStore().publishSipState({
      available: true,
      status: 'connecting',
    });
    await flushPromises();

    expect(toggleButton(wrapper).attributes('data-status')).toBe('connecting');
    expect(
      wrapper.get('[data-testid="sidebar-phone-toggle-status"]').classes()
    ).toContain('bg-n-amber-9');
  });

  it('hides the phone and saves the choice for the current account only', async () => {
    settingsState.settings.value = {
      phone_widget_hidden_accounts: { 5: true },
    };
    const wrapper = mountToggle();
    const button = toggleButton(wrapper);
    expect(button.attributes('aria-label')).toBe('PHONE_WIDGET.SIDEBAR_HIDE');
    expect(button.attributes('title')).toBe('PHONE_WIDGET.SIDEBAR_HIDE');
    expect(button.attributes('data-visible')).toBe('true');

    await button.trigger('click');

    expect(settingsState.update).toHaveBeenCalledWith({
      phone_widget_hidden_accounts: { 1: true, 5: true },
    });
    expect(button.attributes('aria-label')).toBe('PHONE_WIDGET.SIDEBAR_SHOW');
    expect(button.attributes('title')).toBe('PHONE_WIDGET.SIDEBAR_SHOW');
    expect(button.attributes('data-visible')).toBe('false');
  });

  it('shows the phone again and keeps other accounts hidden', async () => {
    settingsState.settings.value = {
      phone_widget_hidden_accounts: { 1: true, 5: true },
    };
    const wrapper = mountToggle();
    expect(toggleButton(wrapper).attributes('aria-label')).toBe(
      'PHONE_WIDGET.SIDEBAR_SHOW'
    );

    await toggleButton(wrapper).trigger('click');

    expect(settingsState.update).toHaveBeenCalledWith({
      phone_widget_hidden_accounts: { 5: true },
    });
    expect(toggleButton(wrapper).attributes('aria-label')).toBe(
      'PHONE_WIDGET.SIDEBAR_HIDE'
    );
  });

  it('reports the phone as shown while a call pops it up and can hide it for that call', async () => {
    settingsState.settings.value = {
      phone_widget_hidden_accounts: { 1: true },
    };
    const wrapper = mountToggle();
    expect(toggleButton(wrapper).attributes('data-visible')).toBe('false');

    useCallsStore().addCall({
      callSid: 'sipuni:incoming-1',
      callDirection: 'inbound',
      provider: 'sipuni',
      status: 'ringing',
    });
    await flushPromises();
    expect(toggleButton(wrapper).attributes('data-visible')).toBe('true');
    expect(toggleButton(wrapper).attributes('aria-label')).toBe(
      'PHONE_WIDGET.SIDEBAR_HIDE'
    );

    await toggleButton(wrapper).trigger('click');

    expect(usePhoneWidgetStore().callDismissed).toBe(true);
    expect(settingsState.update).not.toHaveBeenCalled();
    expect(toggleButton(wrapper).attributes('data-visible')).toBe('false');
  });

  it('shows the action label in the expanded mobile sidebar', () => {
    const wrapper = mountToggle({ isCollapsed: false });

    expect(wrapper.text()).toContain('PHONE_WIDGET.SIDEBAR_HIDE');
    expect(toggleButton(wrapper).classes()).toContain('w-full');
  });
});
