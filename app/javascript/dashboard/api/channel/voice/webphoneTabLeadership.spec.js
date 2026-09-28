import Cookies from 'js-cookie';
import { describe, expect, it, vi } from 'vitest';
import WebphoneTabLeadership, {
  isWebphoneTabOwner,
  webphoneBrowserInstanceId,
  webphoneTabScope,
} from './webphoneTabLeadership';

// Minimal in-memory Web Locks: exclusive locks by name, FIFO queue, `steal`.
const createLocks = () => {
  const locks = new Map();
  const lockFor = name => {
    if (!locks.has(name)) locks.set(name, { holder: null, queue: [] });
    return locks.get(name);
  };

  const grant = (lock, entry) => {
    lock.holder = entry;
    Promise.resolve(entry.callback()).then(
      () => {
        if (lock.holder === entry) {
          lock.holder = null;
          const next = lock.queue.shift();
          if (next) grant(lock, next);
        }
        entry.resolve();
      },
      error => entry.reject(error)
    );
  };

  return {
    request(name, options, callback) {
      const lock = lockFor(name);
      return new Promise((resolve, reject) => {
        const entry = { callback, resolve, reject };
        if (options.steal) {
          const previous = lock.holder;
          lock.holder = null;
          previous?.reject(new DOMException('stolen', 'AbortError'));
          grant(lock, entry);
          return;
        }
        options.signal?.addEventListener('abort', () => {
          const index = lock.queue.indexOf(entry);
          if (index >= 0) lock.queue.splice(index, 1);
          reject(new DOMException('aborted', 'AbortError'));
        });
        if (lock.holder) lock.queue.push(entry);
        else grant(lock, entry);
      });
    },
  };
};

const createChannelBus = () => {
  const channels = new Set();
  return class FakeBroadcastChannel extends EventTarget {
    constructor(name) {
      super();
      this.name = name;
      channels.add(this);
    }

    postMessage(data) {
      channels.forEach(channel => {
        if (channel === this || channel.name !== this.name) return;
        queueMicrotask(() => {
          if (!channels.has(channel)) return;
          channel.dispatchEvent(new MessageEvent('message', { data }));
        });
      });
    }

    close() {
      channels.delete(this);
    }
  };
};

const ACCOUNT_ONE = 'account:1:user:agent';
const ACCOUNT_TWO = 'account:2:user:agent';

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

  it('elects a separate owner for every account so each registers its phone', async () => {
    const locks = createLocks();
    const BroadcastChannelImpl = createChannelBus();
    const firstAccount = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_ONE,
    });
    const secondAccount = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_TWO,
    });
    const firstAccountFollower = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_ONE,
    });
    const followerMessages = vi.fn();
    firstAccountFollower.addEventListener('message', followerMessages);

    [firstAccount, secondAccount, firstAccountFollower].forEach(tab =>
      tab.start()
    );
    await flush();

    expect(firstAccount.isLeader).toBe(true);
    expect(secondAccount.isLeader).toBe(true);
    expect(firstAccountFollower.isLeader).toBe(false);

    secondAccount.post({ type: 'sessions', sessions: [] });
    firstAccount.post({ type: 'sessions', sessions: [] });
    await flush();

    const senders = followerMessages.mock.calls.map(
      ([event]) => event.detail.from
    );
    expect(senders).toContain(firstAccount.tabId);
    expect(senders).not.toContain(secondAccount.tabId);
  });

  it('moves a tab to the owner election of the account it switched to', async () => {
    const locks = createLocks();
    const BroadcastChannelImpl = createChannelBus();
    const releaseOwnership = vi.fn().mockResolvedValue(null);
    const tab = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_ONE,
    });
    const waiting = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_ONE,
    });
    const otherAccountOwner = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_TWO,
      releaseOwnership,
    });
    const changes = [];
    tab.addEventListener('leadership-changed', event =>
      changes.push(event.detail.isLeader)
    );

    tab.start();
    await flush();
    waiting.start();
    otherAccountOwner.start();
    await flush();

    expect(tab.setScope(ACCOUNT_TWO)).toBe(true);
    await flush();

    expect(changes).toEqual([true, false]);
    expect(waiting.isLeader).toBe(true);
    expect(otherAccountOwner.isLeader).toBe(true);
    expect(tab.setScope(ACCOUNT_TWO)).toBe(false);

    await expect(tab.claim()).resolves.toBe(true);
    await flush();

    expect(releaseOwnership).toHaveBeenCalled();
    expect(tab.isLeader).toBe(true);
    expect(otherAccountOwner.isLeader).toBe(false);
    expect(waiting.isLeader).toBe(true);
  });

  it('grants a pending claim when the lock comes free without an answer', async () => {
    const locks = createLocks();
    const BroadcastChannelImpl = createChannelBus();
    const owner = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_ONE,
    });
    const other = new WebphoneTabLeadership({
      locks,
      BroadcastChannelImpl,
      scope: ACCOUNT_ONE,
    });

    owner.start();
    await flush();
    other.start();
    await flush();

    const claim = other.claim();
    owner.stop();
    await flush();

    await expect(claim).resolves.toBe(true);
    expect(other.isLeader).toBe(true);
  });

  it('scopes the election to the account in the URL and the signed-in user', () => {
    const previousPath = window.location.pathname;
    try {
      Cookies.set(
        'cw_d_session_info',
        JSON.stringify({ uid: 'agent@example.com' })
      );
      window.history.pushState({}, '', '/app/accounts/7/dashboard');
      expect(webphoneTabScope()).toBe('account:7:user:agent@example.com');

      Cookies.remove('cw_d_session_info');
      window.history.pushState({}, '', '/app/login');
      expect(webphoneTabScope()).toBe('account:none:user:none');
    } finally {
      Cookies.remove('cw_d_session_info');
      window.history.pushState({}, '', previousPath);
    }
  });
});
