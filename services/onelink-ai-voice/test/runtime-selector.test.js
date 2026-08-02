const test = require('node:test');
const assert = require('node:assert/strict');
const { RuntimeSelector, assertAiRoute } = require('../src/runtime/selector');

const payload = {
  call_ref: 'sipuni:call-42',
  account_id: 42,
  inbox_id: 9,
  provider: 'sipuni',
  routing: { action: 'ai' }
};

test('runtime selector is legacy by default', () => {
  assert.equal(new RuntimeSelector().select(payload), 'legacy');
});

test('runtime selector requires every configured allowlist to match', () => {
  const selector = new RuntimeSelector({
    enabled: true,
    providers: ['sipuni'],
    accountIds: ['42'],
    channelIds: ['9'],
    percentage: 100
  });

  assert.equal(selector.select(payload), 'pipecat');
  assert.equal(selector.select({ ...payload, provider: 'binotel' }), 'legacy');
  assert.equal(selector.select({ ...payload, account_id: 77 }), 'legacy');
  assert.equal(selector.select({ ...payload, inbox_id: 10 }), 'legacy');
});

test('runtime selector exposes a candidate before Rails resolves the AI route', () => {
  const selector = new RuntimeSelector({
    enabled: true,
    providers: ['sipuni'],
    accountIds: ['42'],
    channelIds: ['9'],
    percentage: 100
  });
  const unresolved = { ...payload, routing: undefined };

  assert.equal(selector.selectCandidate(unresolved), 'pipecat');
  assert.equal(selector.select(unresolved), 'legacy');
  assert.equal(selector.selectCandidate({ ...unresolved, inbox_id: 10 }), 'legacy');
});

test('runtime selector requires explicit provider, account, and channel allowlists', () => {
  const config = {
    enabled: true,
    providers: ['sipuni'],
    accountIds: ['42'],
    channelIds: ['9'],
    percentage: 100
  };

  for (const field of ['providers', 'accountIds', 'channelIds']) {
    assert.equal(new RuntimeSelector({ ...config, [field]: [] }).select(payload), 'legacy');
  }
});

test('runtime selector never sends non-AI routes to Pipecat', () => {
  const selector = new RuntimeSelector({
    enabled: true,
    accountIds: ['42'],
    channelIds: ['9'],
    percentage: 100
  });

  for (const action of ['operator', 'human_operator', 'app', 'reject']) {
    assert.equal(selector.select({ ...payload, routing: { action } }), 'legacy');
  }
  assert.equal(selector.select({ ...payload, routing: undefined }), 'legacy');
});

test('runtime selector requires a dedicated voice-agent profile for Janus SIP', () => {
  const selector = new RuntimeSelector({
    enabled: true,
    providers: ['asterisk_analog'],
    accountIds: ['42'],
    channelIds: ['9'],
    percentage: 100
  });
  const janusPayload = {
    ...payload,
    provider: 'asterisk_analog',
    transport: 'janus_sip',
    sip_profile: { profile_kind: 'voice_agent', voice_agent: true }
  };

  assert.equal(selector.select(janusPayload), 'pipecat');
  assert.equal(
    selector.select({
      ...janusPayload,
      sip_profile: { profile_kind: 'human_operator', voice_agent: false }
    }),
    'legacy'
  );
  assert.equal(selector.select({ ...janusPayload, sip_profile: undefined }), 'legacy');
});

test('runtime selector percentage is deterministic for a call', () => {
  const selector = new RuntimeSelector({
    enabled: true,
    providers: ['sipuni'],
    accountIds: ['42'],
    channelIds: ['9'],
    percentage: 50
  });

  assert.equal(selector.select(payload), selector.select(payload));
});

test('non-ai routes are rejected before any runtime selection', () => {
  for (const action of ['operator', 'human_operator', 'app']) {
    assert.throws(
      () => assertAiRoute({ routing: { action } }),
      error => error.code === 'non_ai_route_not_supported' && error.statusCode === 422
    );
  }
  assert.doesNotThrow(() => assertAiRoute(payload));
});

test('missing routing action is rejected before any runtime selection', () => {
  assert.throws(
    () => assertAiRoute({ call_ref: 'missing-route' }),
    error => error.code === 'ai_route_required' && error.statusCode === 422
  );
});
