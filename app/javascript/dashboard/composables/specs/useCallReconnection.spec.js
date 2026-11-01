import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import TelegramPersonalCallsAPI from 'dashboard/api/telegramPersonalCalls';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import {
  handleCallAgentOffer,
  handleAgentOffer,
} from 'dashboard/composables/useWhatsappCallSession';
import { useCallReconnection } from '../useCallReconnection';

vi.mock('dashboard/api/whatsappCalls', () => ({
  default: {
    active: vi.fn(),
    reconnect: vi.fn(),
  },
}));

vi.mock('dashboard/composables/useWhatsappCallSession', () => ({
  handleAgentOffer: vi.fn(async () => ({ success: true })),
  handleCallAgentOffer: vi.fn(async () => ({ success: true })),
}));

vi.mock('dashboard/api/telegramPersonalCalls', async importOriginal => {
  const original = await importOriginal();
  const api = { active: vi.fn(), reconnect: vi.fn() };
  return {
    ...original,
    default: api,
    callsApiFor: value =>
      original.isTelegramPersonalProvider(value)
        ? api
        : original.callsApiFor(value),
  };
});

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
    WhatsappCallsAPI.active.mockResolvedValue({ data: {} });
    TelegramPersonalCallsAPI.active.mockResolvedValue({ data: {} });
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
  it('restores a Telegram call through Janus after page load without requiring a direct SDP offer', async () => {
    window.history.pushState({}, '', '/app/accounts/530/dashboard');
    TelegramPersonalCallsAPI.active.mockResolvedValue({
      data: {
        call: {
          id: 42,
          call_id: 'tg-call',
          provider: 'telegram_personal',
          status: 'in_progress',
          direction: 'incoming',
        },
      },
    });
    const offer = {
      transport: 'janus_audiobridge',
      room_id: 123,
      peer_id: 'peer-1',
    };
    TelegramPersonalCallsAPI.reconnect.mockResolvedValue({ data: offer });
    const wrapper = mountComposable();
    await flushPromises();
    expect(handleCallAgentOffer).toHaveBeenCalledWith(
      42,
      offer,
      expect.objectContaining({
        provider: 'telegram_personal',
        context: 'page-load-reconnect',
      })
    );
    expect(handleAgentOffer).not.toHaveBeenCalled();
    const store = useWhatsappCallsStore();
    expect(store.activeCall).toMatchObject({
      id: 42,
      provider: 'telegram_personal',
      status: 'connected',
      agentWebrtcConnected: true,
    });
    expect(store.isReconnecting).toBe(false);
    wrapper.unmount();
  });

  it('does not overwrite a new call when an old page-load probe resolves', async () => {
    window.history.pushState({}, '', '/app/accounts/530/dashboard');
    let resolveActive;
    WhatsappCallsAPI.active.mockReturnValue(
      new Promise(resolve => {
        resolveActive = resolve;
      })
    );
    const wrapper = mountComposable();
    const store = useWhatsappCallsStore();
    store.setActiveCall({
      id: 99,
      callId: 'new-call',
      provider: 'telegram_personal',
    });
    resolveActive({
      data: { id: 42, call_id: 'old-call', status: 'in_progress' },
    });
    await flushPromises();
    expect(store.activeCall).toMatchObject({ id: 99, callId: 'new-call' });
    expect(WhatsappCallsAPI.reconnect).not.toHaveBeenCalled();
    expect(handleAgentOffer).not.toHaveBeenCalled();
    expect(handleCallAgentOffer).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('discards a page-load reconnect response when its call has ended and a new call owns the media', async () => {
    window.history.pushState({}, '', '/app/accounts/530/dashboard');
    TelegramPersonalCallsAPI.active.mockResolvedValue({
      data: {
        id: 42,
        call_id: 'old-call',
        provider: 'telegram_personal',
        status: 'in_progress',
      },
    });
    let resolveReconnect;
    TelegramPersonalCallsAPI.reconnect.mockReturnValue(
      new Promise(resolve => {
        resolveReconnect = resolve;
      })
    );
    const wrapper = mountComposable();
    await flushPromises();
    const store = useWhatsappCallsStore();
    expect(TelegramPersonalCallsAPI.reconnect).toHaveBeenCalledWith(42);
    store.handleCallEnded('old-call', 42);
    store.setActiveCall({
      id: 99,
      callId: 'new-call',
      provider: 'telegram_personal',
      agentWebrtcConnected: true,
    });
    store.setReconnecting(true);
    resolveReconnect({
      data: {
        transport: 'janus_audiobridge',
        room_id: 123,
        peer_id: 'obsolete-peer',
      },
    });
    await flushPromises();
    expect(store.activeCall).toMatchObject({
      id: 99,
      callId: 'new-call',
      agentWebrtcConnected: true,
    });
    expect(store.isReconnecting).toBe(true);
    expect(handleCallAgentOffer).not.toHaveBeenCalled();
    wrapper.unmount();
  });
});
