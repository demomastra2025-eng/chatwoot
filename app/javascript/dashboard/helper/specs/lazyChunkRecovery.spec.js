import { describe, expect, it, vi } from 'vitest';
import {
  installLazyChunkRecovery,
  STALE_CHUNK_REFRESH_EVENT,
} from '../lazyChunkRecovery';

const createPreloadError = assetPath => {
  const event = new Event('vite:preloadError', { cancelable: true });
  event.payload = new Error(`Unable to preload ${assetPath}`);
  return event;
};

const createWindow = () => {
  const windowRef = new EventTarget();
  windowRef.location = {
    href: 'https://app.example.test/app/accounts/7/conversations/42?view=all#latest',
    reload: vi.fn(),
  };
  return windowRef;
};

describe('lazyChunkRecovery', () => {
  it('shows a refresh action once for a repeated stale chunk failure', () => {
    const windowRef = createWindow();
    const emit = vi.fn();
    const dispose = installLazyChunkRecovery({
      windowRef,
      emit,
      now: () => 100,
    });
    const firstFailure = createPreloadError('/assets/conversation.abc123.js');
    const repeatedFailure = createPreloadError(
      '/assets/conversation.abc123.js'
    );

    windowRef.dispatchEvent(firstFailure);
    windowRef.dispatchEvent(repeatedFailure);

    expect(firstFailure.defaultPrevented).toBe(true);
    expect(repeatedFailure.defaultPrevented).toBe(true);
    expect(emit).toHaveBeenCalledTimes(1);

    const [, notice] = emit.mock.calls[0];
    expect(notice.message).toBe('GENERAL_SETTINGS.STALE_CHUNK_RECOVERY');
    expect(notice.action.type).toBe('callback');
    expect(notice.action.message).toBe('GENERAL_SETTINGS.STALE_CHUNK_REFRESH');

    dispose();
  });

  it('refreshes only after the user selects the action and preserves the current URL', () => {
    const windowRef = createWindow();
    const emit = vi.fn();
    installLazyChunkRecovery({ windowRef, emit, now: () => 100 });
    const beforeRefresh = vi.fn();
    windowRef.addEventListener(STALE_CHUNK_REFRESH_EVENT, beforeRefresh);
    const currentUrl = windowRef.location.href;

    windowRef.dispatchEvent(createPreloadError('/assets/chat.abc123.js'));
    const [, notice] = emit.mock.calls[0];

    expect(windowRef.location.reload).not.toHaveBeenCalled();
    notice.action.onClick();

    expect(windowRef.location.href).toBe(currentUrl);
    expect(windowRef.location.reload).toHaveBeenCalledTimes(1);
    expect(beforeRefresh).toHaveBeenCalledTimes(1);
  });

  it('allows a later failure for the same asset after the bounded notice window', () => {
    const windowRef = createWindow();
    const emit = vi.fn();
    let now = 100;
    installLazyChunkRecovery({ windowRef, emit, now: () => now });

    windowRef.dispatchEvent(createPreloadError('/assets/chat.abc123.js'));
    now += 60_000;
    windowRef.dispatchEvent(createPreloadError('/assets/chat.abc123.js'));

    expect(emit).toHaveBeenCalledTimes(2);
  });
});
