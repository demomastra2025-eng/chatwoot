import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  registerWebphoneLogoutRelease,
  releaseWebphoneBeforeLogout,
  releaseWebphoneWithoutWaiting,
} from './webphoneLogoutRelease';

describe('webphoneLogoutRelease', () => {
  afterEach(() => {
    registerWebphoneLogoutRelease(null);
    vi.useRealTimers();
  });

  it('resolves at once when no browser phone was started', async () => {
    await expect(releaseWebphoneBeforeLogout()).resolves.toBe(false);
  });

  it('waits until the browser phone has been released', async () => {
    const order = [];
    registerWebphoneLogoutRelease(async () => {
      await Promise.resolve();
      order.push('released');
    });

    await expect(releaseWebphoneBeforeLogout()).resolves.toBe(true);
    order.push('after');

    expect(order).toEqual(['released', 'after']);
  });

  it('never rejects when the release fails', async () => {
    registerWebphoneLogoutRelease(() => Promise.reject(new Error('boom')));

    await expect(releaseWebphoneBeforeLogout()).resolves.toBe(false);
  });

  it('never rejects when the release throws synchronously', async () => {
    registerWebphoneLogoutRelease(() => {
      throw new Error('boom');
    });

    await expect(releaseWebphoneBeforeLogout()).resolves.toBe(false);
  });

  it('stops waiting after the timeout so the sign-out never hangs', async () => {
    vi.useFakeTimers();
    registerWebphoneLogoutRelease(() => new Promise(() => {}));
    let settled = null;
    releaseWebphoneBeforeLogout({ timeoutMs: 2_500 }).then(result => {
      settled = result;
    });

    await vi.advanceTimersByTimeAsync(2_400);
    expect(settled).toBe(null);
    await vi.advanceTimersByTimeAsync(200);
    expect(settled).toBe(false);
  });

  it('starts the release without waiting for it', () => {
    const release = vi.fn(() => new Promise(() => {}));
    registerWebphoneLogoutRelease(release);

    expect(() => releaseWebphoneWithoutWaiting()).not.toThrow();
    expect(release).toHaveBeenCalledTimes(1);
  });

  it('ignores a failing release that nobody waits for', async () => {
    registerWebphoneLogoutRelease(() => Promise.reject(new Error('boom')));

    expect(() => releaseWebphoneWithoutWaiting()).not.toThrow();
    await Promise.resolve();
  });
});
