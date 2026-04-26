import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { endClientCallMock, webphoneClientImportedMock } = vi.hoisted(() => ({
  endClientCallMock: vi.fn(),
  webphoneClientImportedMock: vi.fn(),
}));

describe('useCallsStore lazy webphone boundary', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.doMock('dashboard/api/channel/voice/webphoneClient', () => {
      webphoneClientImportedMock();
      return {
        default: {
          endClientCall: endClientCallMock,
        },
      };
    });

    setActivePinia(createPinia());
    endClientCallMock.mockReset();
    webphoneClientImportedMock.mockReset();
  });

  it('does not load browser calling SDKs when the dashboard imports the calls store', async () => {
    await import('./calls');

    expect(webphoneClientImportedMock).not.toHaveBeenCalled();
  });

  it('loads webphone client only when ending an active browser call', async () => {
    const { useCallsStore } = await import('./calls');
    const store = useCallsStore();

    store.addCall({ callSid: 'call-123', provider: 'twilio' });
    store.setCallActive('call-123');

    await store.clearActiveCall();

    expect(webphoneClientImportedMock).toHaveBeenCalledTimes(1);
    expect(endClientCallMock).toHaveBeenCalledWith('twilio');
    expect(store.calls).toEqual([]);
  });

  it('keeps browser cleanup behavior when provider is missing', async () => {
    const { useCallsStore } = await import('./calls');
    const store = useCallsStore();

    store.addCall({ callSid: 'call-456' });
    store.setCallActive('call-456');

    await store.clearActiveCall();

    expect(webphoneClientImportedMock).toHaveBeenCalledTimes(1);
    expect(endClientCallMock).toHaveBeenCalledWith(undefined);
    expect(store.calls).toEqual([]);
  });
});
