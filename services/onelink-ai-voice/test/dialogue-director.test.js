const test = require('node:test');
const assert = require('node:assert/strict');

const { DialogueDirector } = require('../src/dialogue/dialogue-director');

test('DialogueDirector does not announce a failure while a read tool is still pending asynchronously', () => {
  const sentTexts = [];
  const director = new DialogueDirector({
    context: { ai: { tool_failure_phrases: ['Не получилось проверить автоматически.'] } },
    sendText: text => sentTexts.push(text),
    setTimer: () => ({ unref() {} }),
    clearTimer: () => {},
    now: () => 10_000,
  });

  director.finishToolWait(
    { id: 'tool-1', name: 'faq_lookup' },
    { ok: false, pending: true, async: true }
  );

  assert.deepEqual(sentTexts, []);
});

test('DialogueDirector announces a failure when a read tool actually fails', () => {
  const sentTexts = [];
  const director = new DialogueDirector({
    context: { ai: { tool_failure_phrases: ['Не получилось проверить автоматически.'] } },
    sendText: text => sentTexts.push(text),
    now: () => 10_000,
  });

  director.finishToolWait(
    { id: 'tool-1', name: 'faq_lookup' },
    { ok: false, error: 'rails unavailable' }
  );

  assert.equal(sentTexts.length, 1);
  assert.match(sentTexts[0], /Не получилось проверить автоматически/);
});
