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

test('runtime selector requires at least one explicit tenant allowlist', () => {
  const selector = new RuntimeSelector({ enabled: true, providers: ['sipuni'] });

  assert.equal(selector.select(payload), 'legacy');
});

test('runtime selector percentage is deterministic for a call', () => {
  const selector = new RuntimeSelector({
    enabled: true,
    accountIds: ['42'],
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
