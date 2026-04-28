const test = require('node:test');
const assert = require('node:assert/strict');
const { TranscriptBuffer } = require('../src/transcripts/transcript-buffer');

test('TranscriptBuffer batches, deduplicates and flushes partial/final items to Rails', async () => {
  const calls = [];
  const client = { sendTranscript: async (payload) => { calls.push(payload); return { status: 'ok', accepted: payload.items.length }; } };
  const buffer = new TranscriptBuffer({ client, callRef: 'call-1', flushSize: 3 });

  buffer.add({ speaker: 'caller', text: 'hello', final: false, at: 't1' });
  buffer.add({ speaker: 'caller', text: 'hello', final: false, at: 't1' });
  assert.equal(calls.length, 0);

  buffer.add({ speaker: 'ai', text: 'hi', final: true, at: 't2' });
  await buffer.flush({ final: true });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], {
    call_ref: 'call-1',
    final: true,
    items: [
      { speaker: 'caller', text: 'hello', final: false, at: 't1' },
      { speaker: 'ai', text: 'hi', final: true, at: 't2' }
    ]
  });
  assert.equal(buffer.pendingCount, 0);
});
