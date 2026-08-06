const { EventEmitter } = require('node:events');
const crypto = require('node:crypto');
const WebSocket = require('ws');
const { assertAiRoute } = require('../runtime/selector');
const { assertPipecatRuntimeStream } = require('../runtime/pipecat-stream-contract');
const { createJanusRuntimeMediaStreamFactory } = require('./runtime-stream');

const DEFAULT_PLUGIN = 'janus.plugin.sip';
const DEFAULT_PROTOCOL = 'janus-protocol';
const DEFAULT_HANGUP_CONFIRMATION_TIMEOUT_MS = 1500;
const DEFAULT_HANGUP_RECONCILIATION_GRACE_MS = 1500;

class JanusWebSocketClient extends EventEmitter {
  constructor({
    url,
    WebSocketImpl = WebSocket,
    protocol = DEFAULT_PROTOCOL,
    apiSecret = '',
    transactionPrefix = 'onelink-ai-sip',
    requestTimeoutMs = 8000,
    connectTimeoutMs = 8000
  } = {}) {
    super();
    this.url = String(url || '').trim();
    this.WebSocketImpl = WebSocketImpl;
    this.protocol = protocol;
    this.apiSecret = apiSecret;
    this.transactionPrefix = transactionPrefix;
    this.requestTimeoutMs = requestTimeoutMs;
    this.connectTimeoutMs = connectTimeoutMs;
    this.ws = null;
    this.connectPromise = null;
    this.pending = new Map();
  }

  async connect() {
    if (!this.url) throw new Error('janus server WebSocket URL is required');
    if (
      this.ws &&
      (this.ws.readyState === undefined ||
        this.ws.readyState === this.WebSocketImpl.OPEN)
    ) {
      return this;
    }
    if (this.connectPromise) return this.connectPromise;

    this.connectPromise = this.performConnect().finally(() => {
      this.connectPromise = null;
    });
    return this.connectPromise;
  }

  performConnect() {
    const socket = new this.WebSocketImpl(this.url, this.protocol);
    this.ws = socket;
    wireWebSocket(socket, {
      onOpen: () => this.emit('open'),
      onMessage: message => {
        if (this.ws === socket) this.handleMessage(message);
      },
      onClose: () => this.handleClose(socket),
      onError: error => {
        if (this.ws === socket) this.handleError(error);
      }
    });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        if (this.ws === socket) this.ws = null;
        socket.terminate?.();
        socket.close?.();
        reject(new Error('janus websocket connection timed out'));
      }, this.connectTimeoutMs);
      const cleanup = () => {
        clearTimeout(timer);
        this.off('open', onOpen);
        this.off('error', onError);
        this.off('close', onClose);
      };
      const onOpen = () => {
        cleanup();
        resolve(this);
      };
      const onError = error => {
        cleanup();
        reject(error);
      };
      const onClose = () => {
        cleanup();
        reject(new Error('janus websocket closed before open'));
      };
      this.once('open', onOpen);
      this.once('error', onError);
      this.once('close', onClose);
    });
  }

  async createSession() {
    const response = await this.request({ janus: 'create' });
    return response?.data?.id || response?.id;
  }

  async attachPlugin({ sessionId, plugin = DEFAULT_PLUGIN, opaqueId = '' } = {}) {
    const response = await this.request({
      janus: 'attach',
      plugin,
      opaque_id: opaqueId || undefined
    }, { sessionId });
    return response?.data?.id || response?.id;
  }

  async detachPlugin({ sessionId, handleId } = {}) {
    return this.request({ janus: 'detach' }, { sessionId, handleId });
  }

  async destroySession(sessionId) {
    return this.request({ janus: 'destroy' }, { sessionId });
  }

  async keepalive(sessionId) {
    return this.request({ janus: 'keepalive' }, { sessionId });
  }

  async pluginMessage({ sessionId, handleId, body, jsep = null } = {}) {
    return this.request({
      janus: 'message',
      body,
      jsep: jsep || undefined
    }, { sessionId, handleId });
  }

  async request(message = {}, { sessionId = null, handleId = null } = {}) {
    if (!this.ws) await this.connect();
    const socket = this.ws;
    if (!socket) throw new Error('janus websocket is not open');
    const transaction = `${this.transactionPrefix}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
    const payload = compact({
      ...message,
      transaction,
      apisecret: this.apiSecret || undefined,
      session_id: sessionId || undefined,
      handle_id: handleId || undefined
    });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(transaction);
        reject(new Error(`janus request timed out: ${message.janus || 'unknown'}`));
      }, this.requestTimeoutMs);
      this.pending.set(transaction, { resolve, reject, timer });
      try {
        if (socket.readyState !== undefined && socket.readyState !== this.WebSocketImpl.OPEN) {
          throw new Error('janus websocket is not open');
        }
        socket.send(JSON.stringify(payload));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(transaction);
        reject(error);
      }
    });
  }

  handleMessage(message) {
    const payload = parseJson(message);
    if (!payload) return;

    const transaction = payload.transaction;
    if (transaction && this.pending.has(transaction)) {
      const pending = this.pending.get(transaction);
      this.pending.delete(transaction);
      clearTimeout(pending.timer);
      if (payload.janus === 'error' || payload.error) {
        pending.reject(new Error(payload?.error?.reason || payload.error || 'janus error'));
      } else {
        pending.resolve(payload);
      }
      return;
    }

    this.emit('event', payload);
  }

  handleClose(socket = this.ws) {
    if (this.ws !== socket) return;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error('janus websocket closed'));
    }
    this.pending.clear();
    this.ws = null;
    this.emit('close');
  }

  handleError(error) {
    if (this.listenerCount('error') > 0) this.emit('error', error);
  }

  close() {
    this.ws?.close?.();
    this.ws = null;
  }
}

class JanusMediaServerClient {
  constructor({
    baseUrl,
    token,
    fetchImpl = globalThis.fetch,
    timeoutMs = 10000
  } = {}) {
    this.baseUrl = String(baseUrl || '').trim().replace(/\/+$/, '');
    this.token = token || '';
    this.fetchImpl = fetchImpl;
    this.timeoutMs = timeoutMs;
  }

  async ensureSessionOwnershipControls() {
    const payload = await this.get('/health');
    if (payload?.capabilities?.session_ownership_controls === true) return true;

    const error = new Error('media server does not advertise session ownership controls');
    error.code = 'media_server_ownership_controls_unavailable';
    error.statusCode = 503;
    throw error;
  }

  async get(path) {
    if (!this.baseUrl) throw new Error('janus media server URL is required');
    if (typeof this.fetchImpl !== 'function') throw new Error('fetch implementation is required');

    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = controller ? setTimeout(() => controller.abort(), this.timeoutMs) : null;
    try {
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: 'GET',
        headers: { accept: 'application/json' },
        signal: controller?.signal
      });
      const payload = await parseResponse(response);
      if (!response.ok) {
        throw new Error(payload?.error || `media server request failed: ${response.status}`);
      }
      return payload;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  async createSession({
    callId,
    accountId,
    sdpOffer,
    iceServers = [],
    direction = 'incoming',
    recordingEnabled,
    railsCallbacksEnabled
  } = {}) {
    return this.post('/sessions', compact({
      call_id: callId,
      account_id: String(accountId ?? ''),
      direction,
      meta_sdp_offer: sdpOffer,
      ice_servers: iceServers,
      recording_enabled: typeof recordingEnabled === 'boolean' ? recordingEnabled : undefined,
      rails_callbacks_enabled: typeof railsCallbacksEnabled === 'boolean' ? railsCallbacksEnabled : undefined
    }));
  }

  async setMetaAnswer(sessionId, sdpAnswer) {
    return this.post(`/sessions/${encodeURIComponent(sessionId)}/meta-answer`, {
      sdp_answer: sdpAnswer
    });
  }

  async createRuntimeAgent(sessionId, payload = {}) {
    return this.post(`/sessions/${encodeURIComponent(sessionId)}/runtime-agent`, payload);
  }

  async terminateSession(sessionId, reason = 'janus_server_runtime_closed') {
    if (!sessionId) return null;
    return this.post(`/sessions/${encodeURIComponent(sessionId)}/terminate`, { reason });
  }

  async post(path, body) {
    if (!this.baseUrl) throw new Error('janus media server URL is required');
    if (!this.token) throw new Error('janus media server token is required');
    if (typeof this.fetchImpl !== 'function') throw new Error('fetch implementation is required');

    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = controller ? setTimeout(() => controller.abort(), this.timeoutMs) : null;
    try {
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${this.token}`,
          'content-type': 'application/json'
        },
        body: JSON.stringify(body || {}),
        signal: controller?.signal
      });
      const payload = await parseResponse(response);
      if (!response.ok) {
        throw new Error(payload?.error || `media server request failed: ${response.status}`);
      }
      return payload;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

class JanusSipServerRuntimeManager {
  constructor({
    app,
    profiles = [],
    janusUrl,
    mediaServerClient,
    WebSocketImpl = WebSocket,
    runtimeMediaStreamFactory = createJanusRuntimeMediaStreamFactory(),
    profileProvider = null,
    syncIntervalMs = 15000,
    maxCallsPerProfile = 4,
    registrationConcurrency = 10,
    runtimeSelector = null,
    pipecatClient = null,
    pipecatRuntimeControl = null,
    logger = console
  } = {}) {
    if (!app || typeof app.handleCall !== 'function') throw new Error('voice app is required');
    this.app = app;
    this.profiles = profiles.map(normalizeServerProfile).filter(Boolean);
    this.janusUrl = janusUrl;
    this.mediaServerClient = mediaServerClient;
    this.WebSocketImpl = WebSocketImpl;
    this.runtimeMediaStreamFactory = runtimeMediaStreamFactory;
    this.profileProvider = profileProvider;
    this.syncIntervalMs = syncIntervalMs;
    this.maxCallsPerProfile = positiveInteger(maxCallsPerProfile, 4);
    this.registrationConcurrency = positiveInteger(registrationConcurrency, 10);
    this.runtimeSelector = runtimeSelector;
    this.pipecatClient = pipecatClient;
    this.pipecatRuntimeControl = pipecatRuntimeControl;
    this.logger = logger;
    this.sessions = new Map();
    this.syncTimer = null;
    this.syncPromise = null;
    this.lastSyncAt = null;
    this.lastSyncError = null;
    this.consecutiveSyncFailures = 0;
    this.closed = false;
    this.desiredProfileCount = 0;
    this.desiredHandleCount = 0;
    this.failedProfiles = new Map();
  }

  async start() {
    if (!this.mediaServerClient) throw new Error('janus media server client is required');
    this.closed = false;

    if (this.profileProvider) {
      await this.syncProfiles().catch(error => this.log('janus_server_profile_sync_failed', { error: error.message }));
    } else {
      await this.syncProfiles();
    }
    if (!this.closed && this.profileProvider && this.syncIntervalMs > 0) {
      this.scheduleProfileSync();
    }
    return this;
  }

  scheduleProfileSync() {
    if (this.closed || !this.profileProvider || this.syncIntervalMs <= 0 || this.syncTimer) return;

    this.syncTimer = setTimeout(async () => {
      this.syncTimer = null;
      try {
        await this.syncProfiles();
      } catch (error) {
        this.log('janus_server_profile_sync_failed', { error: error.message });
      } finally {
        this.scheduleProfileSync();
      }
    }, this.profileSyncDelayMs());
  }

  profileSyncDelayMs() {
    const failureMultiplier = 2 ** Math.min(this.consecutiveSyncFailures, 6);
    const maximumDelayMs = Math.max(this.syncIntervalMs, 120_000);
    return Math.min(this.syncIntervalMs * failureMultiplier, maximumDelayMs);
  }

  async syncProfiles(profiles = null) {
    if (this.closed) return [];
    if (this.syncPromise) return this.syncPromise;
    this.syncPromise = this.performSyncProfiles(profiles);
    try {
      const result = await this.syncPromise;
      this.lastSyncAt = new Date().toISOString();
      this.lastSyncError = null;
      this.consecutiveSyncFailures = 0;
      return result;
    } catch (error) {
      this.lastSyncError = error.message;
      this.consecutiveSyncFailures += 1;
      throw error;
    } finally {
      this.syncPromise = null;
    }
  }

  async performSyncProfiles(profiles = null) {
    const sourceProfiles = profiles || await this.fetchProfiles();
    const desired = sourceProfiles.map(normalizeServerProfile).filter(Boolean);
    const desiredByKey = new Map(desired.map(profile => [profileKey(profile), profile]));
    this.desiredProfileCount = desiredByKey.size;
    this.desiredHandleCount = desired.reduce(
      (total, profile) => total + positiveInteger(profile.max_concurrent_calls, this.maxCallsPerProfile),
      0
    );
    for (const key of this.failedProfiles.keys()) {
      if (!desiredByKey.has(key)) this.failedProfiles.delete(key);
    }

    for (const [key, session] of this.sessions.entries()) {
      const desiredProfile = desiredByKey.get(key);
      if (!desiredProfile || registrationSignature(desiredProfile) !== session.registrationSignature || !session.isHealthy()) {
        await session.close();
        this.sessions.delete(key);
        this.log('janus_server_profile_unregistered', { profile_id: session.profile.id, account_id: session.profile.account_id, inbox_id: session.profile.inbox_id });
      } else {
        session.updateProfile(desiredProfile);
        await session.ensureDesiredHandles();
      }
    }

    const pendingProfiles = Array.from(desiredByKey.entries()).filter(([key]) => !this.sessions.has(key));
    await mapWithConcurrency(pendingProfiles, this.registrationConcurrency, async ([key, profile]) => {
      const session = new JanusSipServerProfileSession({
        app: this.app,
        profile,
        janusUrl: profile.janus_url || this.janusUrl,
        mediaServerClient: this.mediaServerClient,
        WebSocketImpl: this.WebSocketImpl,
        runtimeMediaStreamFactory: this.runtimeMediaStreamFactory,
        maxCalls: profile.max_concurrent_calls || this.maxCallsPerProfile,
        runtimeSelector: this.runtimeSelector,
        pipecatClient: this.pipecatClient,
        pipecatRuntimeControl: this.pipecatRuntimeControl,
        logger: this.logger
      });
      try {
        await session.start();
        if (this.closed) {
          await session.close();
        } else {
          this.sessions.set(key, session);
          this.failedProfiles.delete(key);
        }
      } catch (error) {
        await session.close();
        this.failedProfiles.set(key, error.message);
        this.log('janus_server_profile_register_failed', {
          profile_id: profile.id,
          account_id: profile.account_id,
          inbox_id: profile.inbox_id,
          error: error.message
        });
      }
    });

    return Array.from(this.sessions.values());
  }

  async fetchProfiles() {
    if (this.profileProvider) {
      return await this.profileProvider();
    }
    return this.profiles;
  }

  async close() {
    this.closed = true;
    if (this.syncTimer) clearTimeout(this.syncTimer);
    this.syncTimer = null;
    await this.syncPromise?.catch?.(() => {});
    await Promise.allSettled(Array.from(this.sessions.values(), session => session.close()));
    this.sessions.clear();
  }

  diagnostics() {
    const sessions = Array.from(this.sessions.values());
    return {
      enabled: true,
      configured_profiles: this.desiredProfileCount,
      healthy_profiles: sessions.filter(session => session.isHealthy() && session.handles.size >= session.maxCalls).length,
      degraded_profiles: sessions.filter(session => session.isHealthy() && session.handles.size < session.maxCalls).length,
      failed_profiles: this.failedProfiles.size,
      registered_handles: sessions.reduce((total, session) => total + session.handles.size, 0),
      desired_handles: this.desiredHandleCount,
      active_calls: sessions.reduce((total, session) => total + session.activeCalls.size, 0),
      last_sync_at: this.lastSyncAt,
      last_sync_error: this.lastSyncError,
      consecutive_sync_failures: this.consecutiveSyncFailures,
      next_sync_delay_ms: this.profileSyncDelayMs()
    };
  }

  log(event, payload = {}) {
    this.logger?.log?.(JSON.stringify({ event, ...compact(payload) }));
  }
}

class JanusSipServerProfileSession {
  constructor({
    app,
    profile,
    janusUrl,
    mediaServerClient,
    WebSocketImpl,
    runtimeMediaStreamFactory,
    maxCalls = 4,
    runtimeSelector = null,
    pipecatClient = null,
    pipecatRuntimeControl = null,
    hangupConfirmationTimeoutMs,
    hangupReconciliationGraceMs,
    logger
  }) {
    this.app = app;
    this.profile = profile;
    this.client = new JanusWebSocketClient({ url: janusUrl, WebSocketImpl });
    this.mediaServerClient = mediaServerClient;
    this.runtimeMediaStreamFactory = runtimeMediaStreamFactory;
    this.maxCalls = positiveInteger(maxCalls, 4);
    this.runtimeSelector = runtimeSelector;
    this.pipecatClient = pipecatClient;
    this.pipecatRuntimeControl = pipecatRuntimeControl;
    this.hangupConfirmationTimeoutMs = hangupConfirmationTimeoutMs;
    this.hangupReconciliationGraceMs = hangupReconciliationGraceMs;
    this.logger = logger;
    this.sessionId = null;
    this.handleId = null;
    this.masterId = null;
    this.handles = new Map();
    this.keepaliveTimer = null;
    this.activeCalls = new Map();
    this.registrationWaiters = new Map();
    this.unregistrationWaiter = null;
    this.registered = false;
    this.connected = false;
    this.closed = false;
    this.closePromise = null;
    this.ensureHandlesPromise = null;
    this.ensureHandlesDirty = false;
    this.lifecycleGeneration = 0;
    this.registrationSignature = registrationSignature(profile);
  }

  async start() {
    this.closed = false;
    const generation = ++this.lifecycleGeneration;
    await this.client.connect();
    this.client.on('event', event => this.handleJanusEvent(event));
    this.client.on('error', error => {
      this.connected = false;
      this.log('janus_server_socket_error', { error: error.message });
    });
    this.client.on('close', () => this.handleSocketClose());
    this.sessionId = await this.client.createSession();
    this.handleId = await this.client.attachPlugin({
      sessionId: this.sessionId,
      plugin: DEFAULT_PLUGIN,
      opaqueId: `onelink-ai-sip-${this.profile.id || this.profile.internal_extension || Date.now()}`
    });
    this.handles.set(String(this.handleId), { id: this.handleId, master: true, activeCallId: null });
    this.masterId = await this.register(this.handleId);
    await this.ensureDesiredHandles();
    this.assertActiveGeneration(generation);
    this.connected = true;
    this.keepaliveTimer = setInterval(() => {
      this.client.keepalive(this.sessionId).catch(error => {
        this.connected = false;
        this.log('janus_server_keepalive_failed', { error: error.message });
      });
    }, this.profile.keepalive_ms || 25000);
    this.log('janus_server_profile_registered', {
      profile_id: this.profile.id,
      account_id: this.profile.account_id,
      inbox_id: this.profile.inbox_id,
      registered_handles: this.handles.size
    });
  }

  async register(handleId, { helper = false } = {}) {
    const sip = this.profile.sip;
    const registration = this.waitForRegistration(handleId);
    const body = helper
      ? { request: 'register', type: 'helper', username: sip.uri, master_id: this.masterId }
      : compact({
        request: 'register',
        username: sip.uri,
        authuser: sip.auth_username || sip.username,
        secret: sip.password,
        proxy: sip.proxy,
        display_name: sip.display_name || this.profile.display_name,
        force_udp: sip.transport !== 'tcp' && sip.transport !== 'tls',
        force_tcp: sip.transport === 'tcp',
        register_ttl: this.profile.register_ttl
      });
    try {
      await this.client.pluginMessage({ sessionId: this.sessionId, handleId, body });
    } catch (error) {
      this.registrationWaiters.get(String(handleId))?.reject(error);
      await registration.catch(() => {});
      throw error;
    }
    const result = await registration;
    return result.master_id || result.masterId || this.masterId;
  }

  async attachHelper(generation = this.lifecycleGeneration) {
    const handleId = await this.client.attachPlugin({
      sessionId: this.sessionId,
      plugin: DEFAULT_PLUGIN,
      opaqueId: `onelink-ai-sip-${this.profile.id}-helper-${crypto.randomBytes(3).toString('hex')}`
    });
    if (!this.isActiveGeneration(generation)) {
      await this.client.detachPlugin({ sessionId: this.sessionId, handleId }).catch(() => {});
      throw new Error('janus SIP profile lifecycle changed during helper attach');
    }
    this.handles.set(String(handleId), { id: handleId, master: false, activeCallId: null });
    try {
      await this.register(handleId, { helper: true });
      this.assertActiveGeneration(generation);
    } catch (error) {
      this.handles.delete(String(handleId));
      await this.client.detachPlugin({ sessionId: this.sessionId, handleId }).catch(() => {});
      throw error;
    }
  }

  async ensureDesiredHandles() {
    this.ensureHandlesDirty = true;
    if (this.ensureHandlesPromise) return this.ensureHandlesPromise;
    const generation = this.lifecycleGeneration;
    this.ensureHandlesPromise = (async () => {
      while (this.ensureHandlesDirty && this.isActiveGeneration(generation)) {
        this.ensureHandlesDirty = false;
        await this.performEnsureDesiredHandles(generation);
      }
    })();
    try {
      return await this.ensureHandlesPromise;
    } finally {
      this.ensureHandlesPromise = null;
      if (this.ensureHandlesDirty && this.isActiveGeneration(generation)) {
        await this.ensureDesiredHandles();
      }
    }
  }

  async performEnsureDesiredHandles(generation) {
    if (!this.isActiveGeneration(generation) || !this.sessionId || !this.masterId) return;
    const missingHandles = Math.max(0, this.maxCalls - this.handles.size);
    if (missingHandles === 0) return;

    await mapWithConcurrency(Array.from({ length: missingHandles }), 4, async () => {
      try {
        await this.attachHelper(generation);
      } catch (error) {
        this.log('janus_server_helper_register_failed', { profile_id: this.profile.id, error: error.message });
      }
    });
  }

  handleSocketClose() {
    this.lifecycleGeneration += 1;
    this.connected = false;
    this.registered = false;
    const error = new Error('janus websocket closed during SIP registration');
    for (const waiter of this.registrationWaiters.values()) waiter.reject(error);
    this.registrationWaiters.clear();
    this.unregistrationWaiter?.resolve(false);
    if (!this.closed) this.log('janus_server_socket_closed', { profile_id: this.profile.id });
    for (const call of this.activeCalls.values()) call.handleJanusEvent('hangup', { reason: 'janus_socket_closed' });
    this.activeCalls.clear();
  }

  isActiveGeneration(generation) {
    const ws = this.client.ws;
    const open = Boolean(ws) && (ws.readyState === undefined || ws.readyState === this.client.WebSocketImpl.OPEN);
    return !this.closed && generation === this.lifecycleGeneration && open;
  }

  assertActiveGeneration(generation) {
    if (!this.isActiveGeneration(generation)) {
      throw new Error('janus websocket closed while starting SIP profile');
    }
  }

  waitForRegistration(handleId, timeoutMs = 10000) {
    const key = String(handleId);
    if (this.registrationWaiters.has(key)) return this.registrationWaiters.get(key).promise;

    let resolveWaiter;
    let rejectWaiter;
    const timer = setTimeout(() => {
      this.registrationWaiters.delete(key);
      rejectWaiter(new Error('janus SIP registration timed out'));
    }, timeoutMs);
    const promise = new Promise((resolve, reject) => {
      resolveWaiter = resolve;
      rejectWaiter = reject;
    });
    const waiter = {
      promise,
      resolve: value => {
        clearTimeout(timer);
        this.registrationWaiters.delete(key);
        resolveWaiter(value);
      },
      reject: error => {
        clearTimeout(timer);
        this.registrationWaiters.delete(key);
        rejectWaiter(error);
      }
    };
    this.registrationWaiters.set(key, waiter);
    return promise;
  }

  handleJanusEvent(event) {
    if (String(event.session_id || '') !== String(this.sessionId || '')) return;
    const handle = this.handles.get(String(event.sender || ''));
    if (!handle) return;

    if (event.janus === 'detached') {
      this.handleDetachedHandle(handle);
      return;
    }

    const data = event?.plugindata?.data || {};
    const result = data.result || data;
    if (data.error_code || data.error) {
      const reason = [data.error_code, data.error].filter(Boolean).join(' ');
      this.registrationWaiters.get(String(handle.id))?.reject(new Error(reason || 'Janus SIP plugin error'));
      this.activeCalls.get(handle.activeCallId)?.handleJanusEvent('plugin_error', data, event);
      this.log('janus_server_plugin_error', { profile_id: this.profile.id, handle_id: handle.id, error: reason });
      return;
    }
    const sipEvent = result.event || data.sip || data.event;
    if (sipEvent === 'registered') {
      if (handle.master) this.registered = true;
      this.registrationWaiters.get(String(handle.id))?.resolve(result);
    } else if (sipEvent === 'registration_failed') {
      if (handle.master) this.registered = false;
      const reason = [result.code, result.reason].filter(Boolean).join(' ') || 'janus SIP registration failed';
      this.registrationWaiters.get(String(handle.id))?.reject(new Error(reason));
    } else if (sipEvent === 'unregistered') {
      if (handle.master) this.registered = false;
      this.unregistrationWaiter?.resolve(true);
    } else if (sipEvent === 'incomingcall') {
      this.handleIncomingCall({ event, result, handle }).catch(error => {
        this.log('janus_server_incoming_failed', { error: error.message });
      });
    } else if (sipEvent === 'hangup') {
      const callId = janusCallId(event, result);
      const resolvedCallId = callId || handle.activeCallId;
      this.activeCalls.get(resolvedCallId)?.handleJanusEvent(sipEvent, result, event);
      this.activeCalls.delete(resolvedCallId);
      handle.activeCallId = null;
    } else {
      const callId = janusCallId(event, result);
      this.activeCalls.get(callId || handle.activeCallId)?.handleJanusEvent(sipEvent, result, event);
    }
  }

  handleDetachedHandle(handle) {
    this.handles.delete(String(handle.id));
    this.registrationWaiters.get(String(handle.id))?.reject(new Error('janus SIP handle detached'));
    if (handle.activeCallId) {
      this.activeCalls.get(handle.activeCallId)?.handleJanusEvent('hangup', { reason: 'janus_handle_detached' });
      this.activeCalls.delete(handle.activeCallId);
    }
    if (handle.master) {
      this.registered = false;
      this.connected = false;
      return;
    }
    if (!this.closed) {
      this.ensureDesiredHandles().catch(error => {
        this.log('janus_server_helper_recovery_failed', { profile_id: this.profile.id, error: error.message });
      });
    }
  }

  async handleIncomingCall({ event, result, handle }) {
    const jsep = event.jsep;
    if (handle.activeCallId && !this.activeCalls.get(handle.activeCallId)?.ended) {
      await this.client.pluginMessage({
        sessionId: this.sessionId,
        handleId: handle.id,
        body: { request: 'decline', code: 486 }
      });
      this.log('janus_server_incoming_busy', { profile_id: this.profile.id });
      return;
    }
    const providerCallId = janusCallId(event, result) || crypto.randomUUID();
    const facade = new JanusSipServerCallFacade({
      profile: this.profile,
      providerCallId,
      caller: result.username || result.displayname || result.display_name,
      janus: {
        client: this.client,
        sessionId: this.sessionId,
        handleId: handle.id,
        jsep,
        log: (eventName, payload) => this.log(eventName, payload)
      },
      mediaServerClient: this.mediaServerClient,
      runtimeMediaStreamFactory: this.runtimeMediaStreamFactory,
      hangupConfirmationTimeoutMs: this.hangupConfirmationTimeoutMs,
      hangupReconciliationGraceMs: this.hangupReconciliationGraceMs
    });
    this.activeCalls.set(providerCallId, facade);
    handle.activeCallId = providerCallId;
    facade.once('end', () => {
      this.activeCalls.delete(providerCallId);
      if (handle.activeCallId === providerCallId) handle.activeCallId = null;
    });
    let run;
    let routeDecision;
    let runtimeEngine;
    try {
      const runtimeCandidate = this.runtimeSelector?.selectCandidate?.(facade.request) || 'legacy';
      if (runtimeCandidate === 'pipecat') facade.request.runtime_engine = 'pipecat';
      routeDecision = await this.resolveRouteDecision(facade);
      if (facade.ended) return;
      facade.request.routing = routeDecision;
      runtimeEngine = this.runtimeSelector?.select?.(facade.request) || 'legacy';
      if (runtimeEngine === 'pipecat') {
        await this.startPipecatCall(facade);
        return;
      }
      run = this.app.handleCall(facade, facade.request);
    } catch (error) {
      this.log('janus_server_handle_call_failed', { error: error.message });
      const routeAction = String(routeDecision?.action || routeDecision?.mode || '').trim().toLowerCase();
      const canFallbackToLegacyAi = runtimeEngine === 'pipecat' &&
        routeAction === 'ai' &&
        this.profile.sip_profile?.profile_kind === 'voice_agent' &&
        this.profile.sip_profile?.voice_agent === true &&
        !facade.acceptAttempted &&
        !facade.acceptRequested &&
        !facade.answered &&
        !facade.ended;
      if (canFallbackToLegacyAi) {
        try {
          routeDecision = await this.app.prepareAiRuntimeFallback?.({
            call: facade,
            requestPayload: facade.request,
            routeDecision,
            error
          });
          if (!routeDecision) throw new Error('AI runtime fallback was not prepared');
          runtimeEngine = 'legacy';
          run = this.app.handleCall(facade, facade.request);
          this.log('janus_server_pipecat_fallback_started', {
            profile_id: this.profile.id,
            call_ref: facade.request.call_ref,
            reason: error.code || error.message
          });
        } catch (fallbackError) {
          this.log('janus_server_pipecat_fallback_failed', { error: fallbackError.message });
          try {
            await this.app.handleAiRuntimeStartFailure?.({
              call: facade,
              requestPayload: facade.request,
              routeDecision,
              error: fallbackError
            });
          } catch (persistenceError) {
            this.log('janus_server_ai_start_failure_persistence_failed', { error: persistenceError.message });
          }
          await facade.hangup().catch(() => {});
          return;
        }
      } else if (runtimeEngine === 'pipecat' && routeAction === 'ai') {
        try {
          await this.app.handleAiRuntimeStartFailure?.({
            call: facade,
            requestPayload: facade.request,
            routeDecision,
            error
          });
        } catch (persistenceError) {
          this.log('janus_server_ai_start_failure_persistence_failed', { error: persistenceError.message });
        }
        await facade.hangup().catch(() => {});
        return;
      } else {
        await facade.hangup().catch(() => {});
        return;
      }
    }
    Promise.resolve(run)
      .then(result => result?.completion?.catch?.(async error => {
        this.log('janus_server_call_completion_failed', { error: error.message });
        await facade.hangup().catch(() => {});
      }))
      .catch(async error => {
        this.log('janus_server_handle_call_failed', { error: error.message });
        await facade.hangup().catch(() => {});
      });
  }

  async resolveRouteDecision(facade) {
    if (!this.app || typeof this.app.routeInboundSafely !== 'function') {
      throw new Error('voice app route resolver is required');
    }
    const routeDecision = await this.app.routeInboundSafely(
      facade.request,
      facade.request.call_ref
    );
    if (!routeDecision || typeof routeDecision !== 'object') {
      throw new Error('voice app returned an invalid route decision');
    }
    return routeDecision;
  }

  async startPipecatCall(facade) {
    assertAiRoute(facade.request);
    if (
      !this.pipecatClient ||
      typeof this.pipecatClient.attachJanus !== 'function' ||
      (typeof this.pipecatClient.isAvailable === 'function' && !this.pipecatClient.isAvailable())
    ) {
      const error = new Error('Pipecat runtime client is not configured');
      error.code = 'pipecat_runtime_unavailable';
      error.statusCode = 503;
      throw error;
    }
    if (typeof this.pipecatClient.ensureAvailable === 'function') {
      await this.pipecatClient.ensureAvailable();
    }
    if (typeof this.pipecatClient.preflightJanus !== 'function') {
      const error = new Error('Pipecat provider preflight is not configured');
      error.code = 'pipecat_preflight_unavailable';
      error.statusCode = 503;
      throw error;
    }
    await this.pipecatClient.preflightJanus(facade.request);
    if (typeof facade.mediaServerClient?.ensureSessionOwnershipControls !== 'function') {
      const error = new Error('media server ownership capability preflight is not configured');
      error.code = 'media_server_ownership_controls_unavailable';
      error.statusCode = 503;
      throw error;
    }
    await facade.mediaServerClient.ensureSessionOwnershipControls();
    facade.enableHangupConfirmation();
    await facade.answer({
      recordingEnabled: false,
      railsCallbacksEnabled: false
    });
    assertPipecatRuntimeStream(facade.request);
    const capability = this.pipecatRuntimeControl?.register?.(facade);
    if (!capability) {
      const error = new Error('Pipecat runtime control is not configured');
      error.code = 'runtime_control_unavailable';
      error.statusCode = 503;
      throw error;
    }
    facade.request.runtime_control = {
      control_url: capability.control_url,
      token: capability.token
    };
    let attached;
    try {
      attached = await this.pipecatClient.attachJanus(facade.request);
    } catch (error) {
      this.pipecatRuntimeControl.release?.(capability.id);
      throw error;
    }
    this.log('janus_server_pipecat_attached', {
      call_ref: facade.request.call_ref,
      account_id: facade.request.account_id,
      inbox_id: facade.request.inbox_id,
      session_id: attached?.session_id
    });
    return attached;
  }

  updateProfile(profile) {
    this.profile = profile;
  }

  async close() {
    if (this.closePromise) return this.closePromise;
    this.closePromise = this.performClose();
    return this.closePromise;
  }

  async performClose() {
    this.closed = true;
    this.lifecycleGeneration += 1;
    if (this.keepaliveTimer) clearInterval(this.keepaliveTimer);
    this.keepaliveTimer = null;
    for (const waiter of this.registrationWaiters.values()) waiter.reject(new Error('janus SIP profile session closed'));
    this.registrationWaiters.clear();
    this.registered = false;
    await Promise.allSettled(Array.from(this.activeCalls.values(), call => call.hangup()));
    this.activeCalls.clear();
    if (this.connected && this.handleId) {
      const unregistered = this.waitForUnregistration();
      await this.client.pluginMessage({
        sessionId: this.sessionId,
        handleId: this.handleId,
        body: { request: 'unregister' }
      }).then(() => unregistered).catch(() => {});
    }
    this.handles.clear();
    if (this.sessionId && this.client.ws) await this.client.destroySession(this.sessionId).catch(() => {});
    this.client.close();
  }

  waitForUnregistration(timeoutMs = 2000) {
    if (this.unregistrationWaiter) return this.unregistrationWaiter.promise;
    let resolveWaiter;
    const promise = new Promise(resolve => { resolveWaiter = resolve; });
    const timer = setTimeout(() => this.unregistrationWaiter?.resolve(false), timeoutMs);
    this.unregistrationWaiter = {
      promise,
      resolve: value => {
        clearTimeout(timer);
        this.unregistrationWaiter = null;
        resolveWaiter(value);
      }
    };
    return promise;
  }

  isHealthy() {
    return !this.closed && this.connected && this.registered && this.handles.size > 0 && Boolean(this.client.ws);
  }

  log(event, payload = {}) {
    this.logger?.log?.(JSON.stringify({ event, ...compact(payload) }));
  }
}

class JanusSipServerCallFacade extends EventEmitter {
  constructor({
    profile,
    providerCallId,
    caller,
    janus,
    mediaServerClient,
    runtimeMediaStreamFactory,
    hangupConfirmationTimeoutMs = DEFAULT_HANGUP_CONFIRMATION_TIMEOUT_MS,
    hangupReconciliationGraceMs = DEFAULT_HANGUP_RECONCILIATION_GRACE_MS
  }) {
    super();
    this.profile = profile;
    this.providerCallId = providerCallId;
    this.janus = janus;
    this.mediaServerClient = mediaServerClient;
    this.runtimeMediaStreamFactory = runtimeMediaStreamFactory;
    this.hangupConfirmationTimeoutMs = Math.max(0, Number(hangupConfirmationTimeoutMs) || 0);
    this.hangupReconciliationGraceMs = Math.max(0, Number(hangupReconciliationGraceMs) || 0);
    this.mediaSessionId = null;
    this.answerPromise = null;
    this.terminationPromise = null;
    this.remoteAnswerWaiter = null;
    this.acceptAttempted = false;
    this.acceptRequested = false;
    this.answered = false;
    this.ended = false;
    this.hangupConfirmationRequired = false;
    this.hangupConfirmationPending = false;
    this.hangupReconciliationTimer = null;
    this.transferLeg = null;
    this.request = buildIncomingRequest({ profile, providerCallId, caller, janus });
  }

  async answer(options = {}) {
    if (this.answered) return true;
    if (this.answerPromise) return this.answerPromise;
    this.answerPromise = this.performAnswer(options);
    try {
      return await this.answerPromise;
    } finally {
      this.answerPromise = null;
    }
  }

  async performAnswer({ recordingEnabled, railsCallbacksEnabled } = {}) {
    const offerless = !this.janus.jsep?.sdp;
    this.ensureAnswerActive('media session creation');
    const mediaSessionRequest = {
      callId: this.request.call_ref,
      accountId: this.request.account_id,
      sdpOffer: this.janus.jsep?.sdp || '',
      iceServers: this.profile.ice_servers || [],
      direction: offerless ? 'outgoing' : 'incoming'
    };
    if (typeof recordingEnabled === 'boolean') mediaSessionRequest.recordingEnabled = recordingEnabled;
    if (typeof railsCallbacksEnabled === 'boolean') mediaSessionRequest.railsCallbacksEnabled = railsCallbacksEnabled;
    const session = await this.mediaServerClient.createSession(mediaSessionRequest);
    if (!session?.session_id) {
      throw new Error('media server returned an invalid Janus session response');
    }
    this.mediaSessionId = session.session_id;
    try {
      const negotiatedSdp = offerless ? session.meta_sdp_offer : session.meta_sdp_answer;
      if (!negotiatedSdp) {
        throw new Error('media server returned an invalid Janus session response');
      }
      this.ensureAnswerActive('runtime agent creation');
      const runtime = await this.mediaServerClient.createRuntimeAgent(this.mediaSessionId, {
        call_ref: this.request.call_ref,
        account_id: String(this.request.account_id || ''),
        conversation_id: String(this.request.conversation_id || ''),
        inbox_id: String(this.request.inbox_id || '')
      });
      this.ensureAnswerActive('Janus accept');
      if (!runtime?.runtime_session_id || !runtime?.stream_url) {
        throw new Error('media server returned an invalid runtime-agent response');
      }
      this.request.runtime_stream = {
        runtime_session_id: runtime.runtime_session_id,
        stream_url: runtime.stream_url,
        stream_token: runtime.stream_token,
        codec: runtime.codec,
        input_sample_rate: runtime.input_sample_rate,
        output_sample_rate: runtime.output_sample_rate,
        input_mime_type: 'audio/pcm;rate=16000',
        output_mime_type: 'audio/pcm;rate=8000'
      };
      this.request.stream_ref = runtime.runtime_session_id;
      this.request.media_session_ref = this.mediaSessionId;
      this.request.janus.media_session_id = this.mediaSessionId;

      const remoteAnswer = offerless ? this.waitForRemoteAnswer() : null;
      this.acceptAttempted = true;
      await this.janus.client.pluginMessage({
        sessionId: this.janus.sessionId,
        handleId: this.janus.handleId,
        body: { request: 'accept', autoaccept_reinvites: true },
        jsep: { type: offerless ? 'offer' : 'answer', sdp: negotiatedSdp }
      });
      this.acceptRequested = true;
      if (remoteAnswer) await remoteAnswer;
      this.ensureAnswerActive('Janus accept acknowledgement');
      this.answered = true;
      return true;
    } catch (error) {
      const waiter = this.remoteAnswerWaiter;
      waiter?.promise.catch(() => {});
      waiter?.reject(error);
      await this.terminateMediaSession('janus_answer_failed');
      throw error;
    }
  }

  ensureAnswerActive(stage) {
    if (this.ended) {
      throw new Error(`Janus call ended during ${stage}`);
    }
  }

  waitForRemoteAnswer(timeoutMs = 10000) {
    if (this.remoteAnswerWaiter) return this.remoteAnswerWaiter.promise;

    let resolveWaiter;
    let rejectWaiter;
    const promise = new Promise((resolve, reject) => {
      resolveWaiter = resolve;
      rejectWaiter = reject;
    });
    const timer = setTimeout(() => {
      this.remoteAnswerWaiter?.reject(new Error('janus offerless answer timed out'));
    }, timeoutMs);
    this.remoteAnswerWaiter = {
      promise,
      resolve: value => {
        clearTimeout(timer);
        this.remoteAnswerWaiter = null;
        resolveWaiter(value);
      },
      reject: error => {
        clearTimeout(timer);
        this.remoteAnswerWaiter = null;
        rejectWaiter(error);
      }
    };
    return promise;
  }

  async stream() {
    return this.runtimeMediaStreamFactory({ request: this.request });
  }

  async dial(payload = {}) {
    return this.transfer(payload);
  }

  async transfer(payload = {}) {
    const uri = payload.agent_aor || payload.agentAor || payload.destination || payload.to || payload.target;
    if (!String(uri || '').trim()) return false;

    const leg = new EventEmitter();
    leg.terminalOutcome = null;
    this.transferLeg = leg;
    this.once('end', () => {
      leg.terminalOutcome ||= 'end';
      leg.emit('end');
    });
    try {
      await this.janus.client.pluginMessage({
        sessionId: this.janus.sessionId,
        handleId: this.janus.handleId,
        body: { request: 'transfer', uri: String(uri).trim() }
      });
      return leg;
    } catch (error) {
      this.transferLeg = null;
      throw error;
    }
  }

  async reject({ code = 486 } = {}) {
    if (this.ended) return true;
    await this.janus.client.pluginMessage({
      sessionId: this.janus.sessionId,
      handleId: this.janus.handleId,
      body: { request: 'decline', code }
    });
    this.emitEnd();
    return true;
  }

  async hangup() {
    if (!this.hangupConfirmationRequired) return this.hangupImmediately();
    if (this.ended) return { accepted: true, confirmed: true, outcome: 'already_ended' };
    const confirmation = this.waitForEndConfirmation();
    let confirmed = false;
    this.hangupConfirmationPending = true;
    try {
      const body = this.answered || this.acceptAttempted || this.acceptRequested
        ? { request: 'hangup' }
        : { request: 'decline', code: 480 };
      await this.janus.client.pluginMessage({
        sessionId: this.janus.sessionId,
        handleId: this.janus.handleId,
        body
      });
      confirmed = await confirmation.promise;
      if (!confirmed) {
        this.janus.log?.('janus_server_hangup_confirmation_timeout', {
          call_ref: this.request.call_ref,
          provider_call_id: this.providerCallId,
          timeout_ms: this.hangupConfirmationTimeoutMs
        });
        // Janus accepted the first command but emitted no terminal SIP event.
        // Retry the idempotent command once before bounded local cleanup.
        await this.janus.client.pluginMessage({
          sessionId: this.janus.sessionId,
          handleId: this.janus.handleId,
          body
        }).catch(error => {
          this.janus.log?.('janus_server_hangup_fallback_failed', {
            call_ref: this.request.call_ref,
            provider_call_id: this.providerCallId,
            error: error.message
          });
        });
      } else {
        this.hangupConfirmationPending = false;
      }
    } finally {
      confirmation.cancel();
      await this.terminateMediaSession();
      if (confirmed) this.emitEnd();
      else this.scheduleHangupReconciliationCleanup();
    }
    return {
      accepted: true,
      confirmed,
      outcome: confirmed ? 'janus_hangup_event' : 'command_retried_after_confirmation_timeout'
    };
  }

  enableHangupConfirmation() {
    this.hangupConfirmationRequired = true;
  }

  async hangupImmediately() {
    if (this.ended) return true;
    try {
      const body = this.answered || this.acceptAttempted || this.acceptRequested
        ? { request: 'hangup' }
        : { request: 'decline', code: 480 };
      await this.janus.client.pluginMessage({
        sessionId: this.janus.sessionId,
        handleId: this.janus.handleId,
        body
      });
    } finally {
      await this.terminateMediaSession();
      this.emitEnd();
    }
    return true;
  }

  waitForEndConfirmation() {
    if (this.ended) {
      return { promise: Promise.resolve(true), cancel() {} };
    }
    let settled = false;
    let timer;
    let resolvePromise;
    const finish = value => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      this.removeListener('end', onEnd);
      resolvePromise(value);
    };
    const onEnd = () => finish(true);
    const promise = new Promise(resolve => { resolvePromise = resolve; });
    this.once('end', onEnd);
    timer = setTimeout(() => finish(false), this.hangupConfirmationTimeoutMs);
    return { promise, cancel: () => finish(false) };
  }

  scheduleHangupReconciliationCleanup() {
    if (this.ended || this.hangupReconciliationTimer) return;
    this.hangupReconciliationTimer = setTimeout(() => {
      this.hangupReconciliationTimer = null;
      if (this.ended) return;
      this.janus.log?.('janus_server_hangup_reconciliation_expired', {
        call_ref: this.request.call_ref,
        provider_call_id: this.providerCallId,
        grace_ms: this.hangupReconciliationGraceMs
      });
      this.emitEnd();
    }, this.hangupReconciliationGraceMs);
    this.hangupReconciliationTimer.unref?.();
  }

  emitEnd() {
    if (this.ended) return;
    clearTimeout(this.hangupReconciliationTimer);
    this.hangupReconciliationTimer = null;
    this.ended = true;
    this.remoteAnswerWaiter?.reject(new Error('janus call ended before remote answer'));
    this.transferLeg = null;
    this.emit('end');
  }

  handleJanusEvent(eventName, result = {}, event = {}) {
    if (eventName === 'hangup') {
      if (this.hangupConfirmationPending) {
        this.hangupConfirmationPending = false;
        this.janus.log?.('janus_server_hangup_confirmed_late', {
          call_ref: this.request.call_ref,
          provider_call_id: this.providerCallId
        });
      }
      this.terminateMediaSession().catch(() => {});
      this.emitEnd();
      return;
    }
    if (eventName === 'accepted' && this.remoteAnswerWaiter) {
      const sdpAnswer = event?.jsep?.sdp;
      if (!sdpAnswer) {
        this.remoteAnswerWaiter.reject(new Error('janus offerless call returned no SDP answer'));
        return;
      }
      this.mediaServerClient
        .setMetaAnswer(this.mediaSessionId, sdpAnswer)
        .then(value => this.remoteAnswerWaiter?.resolve(value))
        .catch(error => this.remoteAnswerWaiter?.reject(error));
      return;
    }
    if (eventName === 'plugin_error') {
      if (this.transferLeg) {
        this.transferLeg.terminalOutcome = 'failed';
        this.transferLeg.emit('failed', result);
      }
      else this.emit('failed', result);
      this.terminateMediaSession('janus_plugin_error').catch(() => {});
      this.emitEnd();
      return;
    }
    if (!this.transferLeg) return;
    if (eventName === 'transferring') {
      this.transferLeg.emit('ringing', result);
      return;
    }
    if (eventName !== 'notify') return;

    const status = sipNotifyStatus(result.content);
    if (status >= 200 && status < 300) {
      this.transferLeg.terminalOutcome = 'answered';
      this.transferLeg.emit('answered', result);
    } else if (status === 486) {
      this.transferLeg.terminalOutcome = 'busy';
      this.transferLeg.emit('busy', result);
    } else if (status === 408 || status === 480) {
      this.transferLeg.terminalOutcome = 'no_answer';
      this.transferLeg.emit('no_answer', result);
    } else if (status >= 300) {
      this.transferLeg.terminalOutcome = 'failed';
      this.transferLeg.emit('failed', result);
    }
  }

  async terminateMediaSession(reason = 'janus_server_runtime_closed') {
    if (!this.mediaSessionId) return null;
    if (!this.terminationPromise) {
      this.terminationPromise = this.mediaServerClient.terminateSession(this.mediaSessionId, reason).catch(() => null);
    }
    return this.terminationPromise;
  }
}

function buildIncomingRequest({ profile, providerCallId, caller, janus }) {
  const callRef = profile.call_ref_prefix
    ? `${profile.call_ref_prefix}${providerCallId}`
    : `${profile.provider}:janus-server:${profile.id || profile.internal_extension}:${providerCallId}`;
  const callerNumber = sipUserPart(caller);
  return compact({
    call_ref: callRef,
    bridge_call_ref: callRef,
    account_id: profile.account_id,
    inbox_id: profile.inbox_id,
    number_ref: profile.number_ref,
    provider: profile.provider,
    app_ref: profile.app_ref,
    direction: 'inbound',
    transport: 'janus_sip',
    caller_number: callerNumber,
    ingress_number: profile.ingress_number || profile.phone_number || profile.number_ref,
    sip_profile: profile.sip_profile,
    janus: {
      plugin: DEFAULT_PLUGIN,
      session_id: janus.sessionId,
      handle_id: janus.handleId,
      call_ref: providerCallId,
      server_runtime: true
    },
    metadata: {
      source: 'server_janus_sip',
      transport: 'janus_sip',
      janus_call_ref: providerCallId,
      voice_agent_sip_profile_id: profile.sip_profile?.id,
      telephony_sip_profile_id: profile.sip_profile?.id,
      target_sip_profile_id: profile.sip_profile?.id,
      browser_join_supported: false
    }
  });
}

function janusCallId(event = {}, result = {}) {
  return result.call_id || result['call-id'] || result.callid ||
    event.call_id || event['call-id'] || event.callid;
}

function sipNotifyStatus(content) {
  const match = String(content || '').match(/SIP\/2\.0\s+(\d{3})/i);
  return match ? Number.parseInt(match[1], 10) : 0;
}

function normalizeServerProfile(profile) {
  const source = typeof profile === 'string' ? parseJson(profile) : profile;
  if (!source || typeof source !== 'object') return null;
  const sipProfile = {
    ...(source.sip_profile || source.sipProfile || {}),
    id: source.sip_profile_id || source.sipProfileId || source.id || source.sip_profile?.id || source.sipProfile?.id,
    profile_kind: 'voice_agent',
    voice_agent: true,
    internal_extension: source.internal_extension || source.internalExtension || source.sip_profile?.internal_extension || source.sipProfile?.internalExtension,
    sip_username: source.sip_username || source.sipUsername || source.sip_profile?.sip_username || source.sipProfile?.sipUsername
  };
  const sip = normalizeSipContract(source.sip || source, sipProfile);
  if (!sip.uri || !sip.password) return null;

  return compact({
    ...source,
    id: sipProfile.id,
    account_id: source.account_id || source.accountId,
    inbox_id: source.inbox_id || source.inboxId,
    number_ref: source.number_ref || source.numberRef,
    provider: source.provider || 'sipuni',
    ingress_number: source.ingress_number || source.ingressNumber || source.phone_number || source.phoneNumber,
    display_name: source.display_name || source.displayName || 'OneLink AI Voice',
    call_ref_prefix: source.call_ref_prefix || source.callRefPrefix,
    janus_url: source.janus_url || source.janusUrl,
    ice_servers: source.ice_servers || source.iceServers || [],
    keepalive_ms: source.keepalive_ms || source.keepaliveMs,
    register_ttl: source.register_ttl || source.registerTtl,
    max_concurrent_calls: source.max_concurrent_calls || source.maxConcurrentCalls,
    sip_profile: sipProfile,
    sip
  });
}

function normalizeSipContract(source, sipProfile = {}) {
  const username = source.sip_username || source.sipUsername || source.username || sipProfile.sip_username;
  const password = source.sip_password || source.sipPassword || source.password || source.secret;
  const host = source.sip_host || source.sipHost || source.host;
  const port = source.sip_port || source.sipPort || source.port || 5060;
  const transport = String(source.sip_transport || source.sipTransport || source.transport || 'udp').toLowerCase();
  const codec = String(source.sip_codec || source.sipCodec || source.codec || '').toLowerCase();
  const uri = source.uri || (username && host ? `sip:${username}@${host}` : '');
  const proxy = normalizeSipProxy(source.proxy || source.sip_proxy || source.sipProxy, { host, port, transport });
  return compact({
    username,
    auth_username: source.auth_username || source.authUsername || username,
    password,
    host,
    port,
    transport,
    codec,
    uri,
    proxy,
    display_name: source.display_name || source.displayName
  });
}

function normalizeSipProxy(value, { host, port, transport }) {
  let proxy = String(value || '').trim();
  if (!proxy && host) proxy = `${host}${port ? `:${port}` : ''}`;
  if (!proxy) return '';
  if (!/^sips?:/i.test(proxy)) proxy = `sip:${proxy}`;
  if ((transport === 'tcp' || transport === 'tls') && !/;transport=/i.test(proxy)) {
    proxy += `;transport=${transport}`;
  }
  return proxy;
}

function parseServerProfilesJson(value) {
  const text = String(value || '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed.map(normalizeServerProfile).filter(Boolean) : [normalizeServerProfile(parsed)].filter(Boolean);
  } catch (_error) {
    return [];
  }
}

function profileKey(profile) {
  return String(profile.id || profile.sip_profile?.id || `${profile.account_id || ''}:${profile.inbox_id || ''}:${profile.internal_extension || profile.sip?.username || ''}`);
}

function profileSignature(profile) {
  return crypto.createHash('sha256').update(JSON.stringify(profile)).digest('hex');
}

function registrationSignature(profile) {
  return profileSignature({
    id: profile.id,
    janus_url: profile.janus_url,
    keepalive_ms: profile.keepalive_ms,
    register_ttl: profile.register_ttl,
    max_concurrent_calls: profile.max_concurrent_calls,
    sip: profile.sip
  });
}

async function mapWithConcurrency(items, concurrency, worker) {
  const queue = Array.from(items);
  const workers = Array.from({ length: Math.min(positiveInteger(concurrency, 1), queue.length) }, async () => {
    while (queue.length > 0) await worker(queue.shift());
  });
  await Promise.all(workers);
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function parseResponse(response) {
  const text = await response.text();
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch (_error) {
    return { raw: text.slice(0, 500) };
  }
}

function parseJson(message) {
  const text = Buffer.isBuffer(message) ? message.toString('utf8') : String(message || '');
  if (!text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch (_error) {
    return null;
  }
}

function wireWebSocket(ws, { onOpen, onMessage, onClose, onError }) {
  ws.once?.('open', onOpen);
  ws.on?.('message', onMessage);
  ws.on?.('close', onClose);
  ws.on?.('error', onError);
}

function sipUserPart(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  const match = raw.match(/sip:([^@;>]+)/i);
  return match?.[1] || raw;
}

function compact(object = {}) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = {
  JanusMediaServerClient,
  JanusSipServerCallFacade,
  JanusSipServerRuntimeManager,
  JanusSipServerProfileSession,
  JanusWebSocketClient,
  normalizeServerProfile,
  parseServerProfilesJson,
  profileKey,
  profileSignature,
  registrationSignature
};
