// Exactly one browser tab owns the SIP registration. The owner holds a Web
// Lock; the browser releases it the moment that tab closes, reloads or
// crashes, so the next queued tab takes over without waiting for the server
// lease to expire. Other tabs mirror the owner's status over BroadcastChannel.

const BROWSER_INSTANCE_STORAGE_KEY = 'onelink:webphone:browser-instance-id';
const LOCK_NAME = 'onelink:webphone:sip-owner';
const CHANNEL_NAME = 'onelink:webphone:tabs';
const HANDOVER_TIMEOUT_MS = 8_000;

const randomId = prefix =>
  window.crypto?.randomUUID?.() ||
  `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`;

let tabOwnsWebphone = true;

// Only the owner tab may present the browser identity: the server lets it
// take the registration lease over from an earlier tab of the same browser.
export const isWebphoneTabOwner = () => tabOwnsWebphone;

// Shared by all tabs of this browser and stable across reloads, so the server
// registration lease follows the phone to whichever tab currently owns it.
export const webphoneBrowserInstanceId = () => {
  try {
    const existing = window.localStorage.getItem(BROWSER_INSTANCE_STORAGE_KEY);
    if (existing) return existing;

    const created = randomId('webphone-browser');
    window.localStorage.setItem(BROWSER_INSTANCE_STORAGE_KEY, created);
    return created;
  } catch {
    return null;
  }
};

export default class WebphoneTabLeadership extends EventTarget {
  constructor({
    locks = typeof navigator !== 'undefined' ? navigator.locks : null,
    BroadcastChannelImpl = typeof BroadcastChannel !== 'undefined'
      ? BroadcastChannel
      : null,
    canHandOver = () => true,
    releaseOwnership = async () => {},
  } = {}) {
    super();
    this.locks = locks;
    this.tabId = randomId('webphone-tab');
    this.canHandOver = canHandOver;
    this.releaseOwnership = releaseOwnership;
    this.supported = Boolean(locks?.request && BroadcastChannelImpl);
    this.isLeader = !this.supported;
    tabOwnsWebphone = this.isLeader;
    this.releaseLock = null;
    this.lockAbort = null;
    this.pendingHandover = null;
    this.channel = this.supported
      ? new BroadcastChannelImpl(CHANNEL_NAME)
      : null;
    this.channel?.addEventListener('message', event =>
      this.handleMessage(event.data || {})
    );
  }

  start() {
    if (!this.supported || this.started) return;

    this.started = true;
    this.queueForLock();
    this.post({ type: 'hello' });
  }

  queueForLock({ steal = false } = {}) {
    this.lockAbort?.abort();
    const abort = new AbortController();
    this.lockAbort = abort;
    const options = steal ? { steal: true } : { signal: abort.signal };

    this.locks
      .request(
        LOCK_NAME,
        options,
        () =>
          new Promise(resolve => {
            this.releaseLock = resolve;
            this.setLeader(true);
          })
      )
      .catch(() => null)
      .finally(() => {
        // A superseded request was aborted on purpose; anything else means the
        // lock was stolen by a tab that asked for the phone, so queue again to
        // take over when that tab goes away.
        if (this.lockAbort !== abort || !this.started) return;

        this.lockAbort = null;
        this.releaseLock = null;
        this.setLeader(false);
        this.queueForLock();
      });
  }

  setLeader(isLeader) {
    if (this.isLeader === isLeader) return;

    this.isLeader = isLeader;
    tabOwnsWebphone = isLeader;
    this.dispatchEvent(
      new CustomEvent('leadership-changed', { detail: { isLeader } })
    );
  }

  // Asks the current owner to give up the phone so this tab can use it.
  // Resolves false when the owner is busy with a call or does not answer.
  claim() {
    if (!this.supported || this.isLeader) return Promise.resolve(true);
    if (this.pendingHandover) return this.pendingHandover.promise;

    const requestId = randomId('webphone-handover');
    let settle;
    const promise = new Promise(resolve => {
      settle = resolve;
    });
    const timer = window.setTimeout(
      () => this.pendingHandover?.settle(false),
      HANDOVER_TIMEOUT_MS
    );
    this.pendingHandover = {
      requestId,
      promise,
      settle: result => {
        window.clearTimeout(timer);
        this.pendingHandover = null;
        settle(result);
      },
    };
    this.post({ type: 'handover-request', requestId, to: null });
    return promise;
  }

  async handleMessage(message) {
    if (message.from === this.tabId) return;

    if (message.type === 'handover-request' && this.isLeader) {
      if (!this.canHandOver()) {
        this.post({
          type: 'handover-denied',
          requestId: message.requestId,
          to: message.from,
        });
        return;
      }
      const heldLock = this.lockAbort;
      this.setLeader(false);
      await this.releaseOwnership();
      this.post({
        type: 'handover-ready',
        requestId: message.requestId,
        to: message.from,
      });
      // If the requesting tab vanished before stealing the lock, nobody would
      // own the phone; take it back.
      window.setTimeout(() => {
        if (this.started && this.lockAbort === heldLock && !this.isLeader) {
          this.setLeader(true);
        }
      }, HANDOVER_TIMEOUT_MS);
      return;
    }

    if (message.to && message.to !== this.tabId) return;
    if (message.type === 'handover-ready') {
      // Steal even when the claim already timed out: the owner has released
      // the phone for this tab and waits for the lock to move.
      this.queueForLock({ steal: true });
      this.pendingHandover?.settle(true);
      return;
    }
    if (message.type === 'handover-denied') {
      if (this.pendingHandover?.requestId === message.requestId) {
        this.pendingHandover.settle(false);
      }
      return;
    }

    this.dispatchEvent(new CustomEvent('message', { detail: message }));
  }

  post(message) {
    this.channel?.postMessage({ ...message, from: this.tabId });
  }

  stop() {
    this.lockAbort?.abort();
    this.releaseLock?.();
    this.channel?.close();
    this.started = false;
  }
}
