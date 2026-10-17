import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it } from 'vitest';

import {
  SELECTED_INBOX_STORAGE_KEY,
  phoneLineProviderLabel,
  phoneWidgetStatusColor,
  usePhoneWidgetStore,
} from './phoneWidget';

describe('phoneWidget store', () => {
  beforeEach(() => {
    window.localStorage?.clear?.();
    setActivePinia(createPinia());
  });

  it('starts without a phone line', () => {
    const store = usePhoneWidgetStore();

    expect(store.available).toBe(false);
    expect(store.status).toBe('disconnected');
    expect(store.callDismissed).toBe(false);
    expect(store.preparingOutboundCalls).toBe(0);
    expect(store.selectedInboxId).toBeNull();
    expect(store.linesStatusById).toEqual({});
  });

  it('publishes the SIP line state and per-line statuses of the widget', () => {
    const store = usePhoneWidgetStore();

    store.publishSipState({
      available: true,
      status: 'ownerTab',
      linesStatusById: { 43: 'ownerTab', 44: 'ready' },
    });
    expect(store.available).toBe(true);
    expect(store.status).toBe('ownerTab');
    expect(store.linesStatusById).toEqual({ 43: 'ownerTab', 44: 'ready' });

    store.publishSipState({ available: false });
    expect(store.available).toBe(false);
    expect(store.status).toBe('disconnected');
    expect(store.linesStatusById).toEqual({});
  });

  it('persists the selected outbound inbox id in localStorage', () => {
    const store = usePhoneWidgetStore();

    store.setSelectedInboxId(44);
    expect(store.selectedInboxId).toBe('44');
    expect(window.localStorage.getItem(SELECTED_INBOX_STORAGE_KEY)).toBe('44');

    setActivePinia(createPinia());
    const hydratedStore = usePhoneWidgetStore();
    expect(hydratedStore.selectedInboxId).toBe('44');

    hydratedStore.setSelectedInboxId(null);
    expect(hydratedStore.selectedInboxId).toBeNull();
    expect(window.localStorage.getItem(SELECTED_INBOX_STORAGE_KEY)).toBeNull();
  });

  it('formats human-readable provider labels for voice and WhatsApp lines', () => {
    expect(
      phoneLineProviderLabel({ channel_type: 'Channel::Whatsapp' })
    ).toBe('WhatsApp');
    expect(phoneLineProviderLabel({ provider: 'wazo' })).toBe(
      'Wazo / Asterisk'
    );
    expect(phoneLineProviderLabel({ provider: 'asterisk_analog' })).toBe(
      'Wazo / Asterisk'
    );
    expect(phoneLineProviderLabel({ provider: 'sipuni' })).toBe('Sipuni');
    expect(phoneLineProviderLabel({ provider: 'binotel' })).toBe('Binotel');
    expect(phoneLineProviderLabel({ provider: 'beeline' })).toBe('Beeline');
  });

  it('counts outbound calls being prepared without going negative', () => {
    const store = usePhoneWidgetStore();

    store.beginOutboundCall();
    store.beginOutboundCall();
    expect(store.preparingOutboundCalls).toBe(2);

    store.finishOutboundCall();
    store.finishOutboundCall();
    store.finishOutboundCall();
    expect(store.preparingOutboundCalls).toBe(0);
  });

  it.each([
    ['ready', 'bg-n-teal-9'],
    ['ownerTab', 'bg-n-teal-9'],
    ['connecting', 'bg-n-amber-9'],
    ['standby', 'bg-n-slate-9'],
    ['disconnected', 'bg-n-slate-9'],
    ['error', 'bg-n-ruby-9'],
    ['unexpected', 'bg-n-ruby-9'],
  ])('colours the %s status', (status, colour) => {
    expect(phoneWidgetStatusColor(status)).toBe(colour);
  });
});
