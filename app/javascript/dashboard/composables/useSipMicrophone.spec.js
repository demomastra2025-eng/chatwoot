import { mount } from '@vue/test-utils';
import { defineComponent, nextTick, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const { client, listeners } = vi.hoisted(() => ({
  listeners: new Map(),
  client: {
    microphoneState: vi.fn(),
    toggleMicrophone: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  },
}));

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: client,
}));

import { useSipMicrophone } from './useSipMicrophone';

const sipCall = (overrides = {}) => ({
  isActive: true,
  provider: 'sipuni',
  inboxId: 43,
  sipProfileId: 83,
  janusSessionKey: 'sip_profile:83',
  callSid: 'sipuni:call-1',
  janusCallRef: 'janus-1',
  ...overrides,
});

const mountComposable = call => {
  let result;
  const wrapper = mount(
    defineComponent({
      setup() {
        result = useSipMicrophone(call);
        return () => null;
      },
    })
  );
  return { wrapper, result };
};

const emit = eventName => {
  listeners.get(eventName)?.forEach(listener => listener());
};

describe('useSipMicrophone', () => {
  beforeEach(() => {
    listeners.clear();
    client.microphoneState.mockReset().mockReturnValue({
      available: false,
      muted: false,
    });
    client.toggleMicrophone.mockReset().mockReturnValue(true);
    client.addEventListener.mockReset().mockImplementation((name, fn) => {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(fn);
    });
    client.removeEventListener.mockReset().mockImplementation((name, fn) => {
      listeners.get(name)?.delete(fn);
      if (!listeners.get(name)?.size) listeners.delete(name);
    });
  });

  it('keeps the microphone disabled without an active call or connected media', async () => {
    const call = ref(null);
    const { wrapper, result } = mountComposable(call);
    expect(result.microphoneAvailable.value).toBe(false);
    expect(result.toggleMicrophone()).toBe(false);
    expect(client.microphoneState).not.toHaveBeenCalled();

    call.value = sipCall({ isActive: false });
    await nextTick();
    expect(result.microphoneAvailable.value).toBe(false);

    call.value = sipCall();
    await nextTick();
    expect(result.microphoneAvailable.value).toBe(false);
    expect(result.toggleMicrophone()).toBe(false);
    expect(client.toggleMicrophone).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it('targets the active SIP branch and refreshes both views on media/mute events', async () => {
    const call = ref(sipCall());
    const first = mountComposable(call);
    const second = mountComposable(call);
    client.microphoneState.mockReturnValue({ available: true, muted: false });
    emit('call:connected');
    await nextTick();

    expect(first.result.microphoneAvailable.value).toBe(true);
    expect(client.microphoneState).toHaveBeenCalledWith({
      provider: 'sipuni',
      inboxId: 43,
      sipProfileId: 83,
      sessionKey: 'sip_profile:83',
      callRef: 'sipuni:call-1',
      janusCallRef: 'janus-1',
    });
    expect(first.result.toggleMicrophone()).toBe(true);
    expect(client.toggleMicrophone).toHaveBeenCalledWith(
      expect.objectContaining({ sipProfileId: 83, callRef: 'sipuni:call-1' })
    );

    client.microphoneState.mockReturnValue({ available: true, muted: true });
    emit('call:microphone-state');
    await nextTick();
    expect(first.result.microphoneMuted.value).toBe(true);
    expect(second.result.microphoneMuted.value).toBe(true);

    call.value = null;
    emit('call:disconnected');
    await nextTick();
    expect(first.result.microphoneAvailable.value).toBe(false);
    expect(first.result.microphoneMuted.value).toBe(false);
    first.wrapper.unmount();
    second.wrapper.unmount();
    expect(listeners.size).toBe(0);
  });
});
