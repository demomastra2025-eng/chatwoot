import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import { useCallReconnection } from '../useCallReconnection';

vi.mock('dashboard/api/whatsappCalls', () => ({
  default: {
    active: vi.fn(),
    reconnect: vi.fn(),
  },
}));

vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  handleAgentOffer: vi.fn(async () => ({ success: true })),
}));

const mountComposable = () =>
  mount(
    defineComponent({
      setup() {
        useCallReconnection();
        return () => h('div');
      },
    }),
    {
      global: {
        plugins: [createPinia()],
      },
    }
  );

describe('useCallReconnection', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    window.history.pushState({}, '', '/');
  });

  it('does not probe the active WhatsApp call endpoint outside account routes', async () => {
    window.history.pushState({}, '', '/app/login');

    mountComposable();
    await flushPromises();

    expect(WhatsappCallsAPI.active).not.toHaveBeenCalled();
  });

  it('checks for active calls on account-scoped routes', async () => {
    window.history.pushState({}, '', '/app/accounts/530/dashboard');
    WhatsappCallsAPI.active.mockResolvedValue({ data: {} });

    mountComposable();
    await flushPromises();

    expect(WhatsappCallsAPI.active).toHaveBeenCalledTimes(1);
  });
});
