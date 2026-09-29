import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it } from 'vitest';

import { phoneWidgetStatusColor, usePhoneWidgetStore } from './phoneWidget';

describe('phoneWidget store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('starts without a phone line', () => {
    const store = usePhoneWidgetStore();

    expect(store.available).toBe(false);
    expect(store.status).toBe('disconnected');
    expect(store.callDismissed).toBe(false);
    expect(store.preparingOutboundCalls).toBe(0);
  });

  it('publishes the SIP line state of the widget', () => {
    const store = usePhoneWidgetStore();

    store.publishSipState({ available: true, status: 'ownerTab' });
    expect(store.available).toBe(true);
    expect(store.status).toBe('ownerTab');

    store.publishSipState({ available: false });
    expect(store.available).toBe(false);
    expect(store.status).toBe('disconnected');
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
