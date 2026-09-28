import { describe, expect, it, vi } from 'vitest';
import WebphoneTabLeadership, {
  isWebphoneTabOwner,
  webphoneBrowserInstanceId,
} from './webphoneTabLeadership';

// Minimal in-memory Web Locks: one exclusive lock, FIFO queue, `steal`.
const createLocks = () => {
  let holder = null;
  const queue = [];

  const grant = entry => {
    holder = entry;
    Promise.resolve(entry.callback()).then(
      () => {
        if (holder === entry) {
          holder = null;
          const next = queue.shift();
          if (next) grant(next);
        }
        entry.resolve();
      },
      error => entry.reject(error)
    );
  };

  return {
    request(name, options, callback) {
      return new Promise((resolve, reject) => {
        const entry = { callback, resolve, reject };
        if (options.steal) {
          const previous = holder;
          holder = null;
          previous?.reject(new DOMException('stolen', 'AbortError'));
          grant(entry);
          return;
        }
        options.signal?.addEventListener('abort', () => {
          const index = queue.indexOf(entry);
          if (index >= 0) queue.splice(index, 1);
          reject(new DOMException('aborted', 'AbortError'));
        });
        if (holder) queue.push(entry);
        else grant(entry);
      });
    },
  };
};

const createChannelBus = () => {
  const channels = new Set();
  return class FakeBroadcastChannel extends EventTarget {
    constructor() {
      super();
      channels.add(this);
    }

    postMessage(data) {
      channels.forEach(channel => {
        if (channel === this) return;
        queueMicrotask(() =>
          channel.dispatchEvent(new MessageEvent('message', { data }))
        );
      });
    }

    close() {
      channels.delete(this);
    }
  };
};

const flush = () =>
  new Promise(resolve => {
    setTimeout(resolve, 0);
  });

describe('WebphoneTabLeadership', () => {
  it('acts as the owner when the browser has no Web Locks', () => {
    const leadership = new WebphoneTabLeadership({ locks: null });

    expect(leadership.isLeader).toBe(true);
    expect(isWebphoneTabOwner()).toBe(true);
  });

  it('keeps a stable browser instance id across calls', () => {
    const first = webphoneBrowserInstanceId();

    expect(first).toBeTruthy();
    expect(webphoneBrowserInstanceId()).toBe(first);
  });

  it('elects one owner and hands the phone over on request', async () => {
    const locks = createLocks();
    const BroadcastChannelImpl = createChannelBus();
    const releaseOwnership = vi.fn().mockResolvedValue(null);
    const owner = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      releaseOwnership,
    });
    const other = new WebphoneTabLeadership({ locks, BroadcastChannelImpl });

    owner.start();
    await flush();
    other.start();
    await flush();

    expect(owner.isLeader).toBe(true);
    expect(other.isLeader).toBe(false);

    await expect(other.claim()).resolves.toBe(true);
    await flush();

    expect(releaseOwnership).toHaveBeenCalled();
    expect(other.isLeader).toBe(true);
    expect(owner.isLeader).toBe(false);
  });

  it('refuses a handover while the owner has a call in progress', async () => {
    const locks = createLocks();
    const BroadcastChannelImpl = createChannelBus();
    const owner = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      canHandOver: () => false,
    });
    const other = new WebphoneTabLeadership({ locks, BroadcastChannelImpl });

    owner.start();
    await flush();
    other.start();
    await flush();

    await expect(other.claim()).resolves.toBe(false);
    expect(owner.isLeader).toBe(true);
    expect(other.isLeader).toBe(false);
  });

  it('passes ownership to a waiting tab when the owner tab goes away', async () => {
    const locks = createLocks();
    const BroadcastChannelImpl = createChannelBus();
    const owner = new WebphoneTabLeadership({ locks, BroadcastChannelImpl });
    const other = new WebphoneTabLeadership({ locks, BroadcastChannelImpl });

    owner.start();
    await flush();
    other.start();
    await flush();

    owner.stop();
    await flush();

    expect(other.isLeader).toBe(true);
  });
});
