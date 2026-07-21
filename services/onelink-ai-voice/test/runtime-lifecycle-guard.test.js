const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const {
  createRuntimeLifecycleGuard,
  routeMaxCallDurationSeconds
} = require('../src/app/voice-application');

test('routeMaxCallDurationSeconds applies defaults and safe channel bounds', () => {
  assert.equal(routeMaxCallDurationSeconds({}), 1800);
  assert.equal(routeMaxCallDurationSeconds({ max_call_duration_seconds: 120 }), 300);
  assert.equal(routeMaxCallDurationSeconds({ max_call_duration_seconds: 3600 }), 3600);
  assert.equal(routeMaxCallDurationSeconds({ max_call_duration_seconds: 20_000 }), 14_400);
});

test('runtime lifecycle guard heartbeats and terminalizes transport at the hard limit', async () => {
  const heartbeats = [];
  const closed = [];
  const hangups = [];
  const registryClosures = [];
  const order = [];
  const call = Object.assign(new EventEmitter(), {
    async hangup(payload) { order.push('hangup'); hangups.push(payload); }
  });
  const session = {
    callRef: 'call-hard-limit-1',
    aiSessionId: 'runtime-hard-limit-1',
    scopedPayload(extra) { return { call_ref: this.callRef, ...extra }; },
    async close(action, metadata) { order.push('finalize'); closed.push({ action, metadata }); }
  };
  const app = {
    client: {
      async sendHeartbeat(payload) {
        heartbeats.push(payload);
        return { status: 'ok', terminal: false };
      }
    },
    registry: { close: (...args) => { order.push('registry'); registryClosures.push(args); } }
  };

  const guard = createRuntimeLifecycleGuard({
    app,
    call,
    session,
    routeDecision: { max_call_duration_seconds: 1800 },
    heartbeatIntervalMs: 0
  });
  await new Promise(resolve => setImmediate(resolve));
  await guard.enforceMaxDuration();

  assert.equal(heartbeats.length, 1);
  assert.equal(heartbeats[0].runtime_engine, 'onelink-ai-voice-node');
  assert.deepEqual(closed, [{
    action: 'end_call',
    metadata: {
      final_status: 'completed',
      reason: 'max_duration',
      ended_by: 'system',
      source: 'runtime_lifecycle_guard'
    }
  }]);
  assert.deepEqual(hangups, [{ reason: 'max_duration' }]);
  assert.deepEqual(registryClosures, [['call-hard-limit-1', 'max_duration']]);
  assert.deepEqual(order, ['hangup', 'registry', 'finalize']);
});

test('hard limit hangs up transport even while finalization is blocked', async () => {
  let releaseFinalization;
  const hangups = [];
  const call = Object.assign(new EventEmitter(), {
    async hangup(payload) { hangups.push(payload); }
  });
  const session = {
    callRef: 'call-blocked-finalize-1',
    aiSessionId: 'runtime-blocked-finalize-1',
    scopedPayload(extra) { return { account_id: 1, call_ref: this.callRef, ...extra }; },
    close() { return new Promise(resolve => { releaseFinalization = resolve; }); }
  };
  const guard = createRuntimeLifecycleGuard({
    app: { client: {}, registry: { close() {} } },
    call,
    session,
    heartbeatIntervalMs: 0,
    maxDurationSeconds: 300
  });

  const termination = guard.enforceMaxDuration();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(hangups, [{ reason: 'max_duration' }]);

  releaseFinalization();
  await termination;
});
