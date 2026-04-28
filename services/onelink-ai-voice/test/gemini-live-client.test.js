const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { GeminiLiveClient, buildGeminiLiveUrl } = require('../src/realtime/gemini-live-client');

class FakeSocket extends EventEmitter {
  constructor(url, options = {}) {
    super();
    this.url = url;
    this.options = options;
    this.sent = [];
    this.readyState = FakeSocket.CONNECTING;
    FakeSocket.instances.push(this);
  }

  open() {
    this.readyState = FakeSocket.OPEN;
    this.emit('open');
  }

  receive(payload) {
    this.emit('message', Buffer.from(JSON.stringify(payload)));
  }

  send(payload) {
    this.sent.push(JSON.parse(payload));
  }

  close() {
    this.readyState = FakeSocket.CLOSED;
    this.emit('close', 1000, Buffer.from('normal'));
  }
}
FakeSocket.CONNECTING = 0;
FakeSocket.OPEN = 1;
FakeSocket.CLOSED = 3;
FakeSocket.instances = [];

test('GeminiLiveClient connects without leaking api key in URL and bridges audio, transcripts, tools and interrupts', async () => {
  FakeSocket.instances = [];
  const audio = [];
  const transcripts = [];
  const interruptions = [];
  const toolCalls = [];

  const client = new GeminiLiveClient({
    apiKey: 'secret-token-123',
    model: 'gemini-live-test',
    voice: 'Puck',
    language: 'ru-KZ',
    WebSocketImpl: FakeSocket,
    onAudio: chunk => audio.push(chunk),
    onTranscript: item => transcripts.push(item),
    onInterrupt: () => interruptions.push('interrupt'),
    onToolCall: async call => {
      toolCalls.push(call);
      return { ok: true, result: { found: true } };
    }
  });

  const connectPromise = client.connect({
    systemPrompt: 'Ты голосовой оператор OneLink.',
    tools: [{
      name: 'lookup_customer',
      description: 'Lookup customer',
      parameters: { type: 'object', properties: { phone: { type: 'string' } } }
    }]
  });

  const socket = FakeSocket.instances[0];
  assert.ok(socket, 'websocket should be created');
  assert.equal(socket.options.headers['x-goog-api-key'], 'secret-token-123');
  assert.equal(socket.url.includes('secret-token-123'), false, 'api key must not be placed in URL');

  socket.open();
  assert.equal(socket.sent[0].setup.model, 'models/gemini-live-test');
  assert.equal(socket.sent[0].setup.generationConfig.responseModalities[0], 'AUDIO');
  assert.equal(socket.sent[0].setup.realtimeInputConfig.activityHandling, 'START_OF_ACTIVITY_INTERRUPTS');
  assert.equal(socket.sent[0].setup.systemInstruction.parts[0].text, 'Ты голосовой оператор OneLink.');
  assert.equal(socket.sent[0].setup.tools[0].functionDeclarations[0].name, 'lookup_customer');

  socket.receive({ setupComplete: {} });
  await connectPromise;

  client.sendAudio(Buffer.from([1, 2, 3]), { mimeType: 'audio/pcm;rate=16000' });
  assert.deepEqual(socket.sent.at(-1).realtimeInput.audio.data, Buffer.from([1, 2, 3]).toString('base64'));

  socket.receive({
    serverContent: {
      inputTranscription: { text: 'алло' },
      outputTranscription: { text: 'здравствуйте' },
      modelTurn: { parts: [{ inlineData: { mimeType: 'audio/pcm;rate=24000', data: Buffer.from([4, 5]).toString('base64') } }] },
      interrupted: true
    }
  });

  assert.deepEqual(transcripts.map(item => [item.speaker, item.text]), [['caller', 'алло'], ['ai', 'здравствуйте']]);
  assert.deepEqual(audio[0], Buffer.from([4, 5]));
  assert.equal(interruptions.length, 1);

  socket.receive({
    toolCall: { functionCalls: [{ id: 'tool-1', name: 'lookup_customer', args: { phone: '+7700' } }] }
  });
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(toolCalls[0].name, 'lookup_customer');
  assert.deepEqual(toolCalls[0].args, { phone: '+7700' });
  assert.equal(socket.sent.at(-1).toolResponse.functionResponses[0].id, 'tool-1');
  assert.deepEqual(socket.sent.at(-1).toolResponse.functionResponses[0].response, { ok: true, result: { found: true } });
});

test('buildGeminiLiveUrl includes model but never includes API key', () => {
  const url = buildGeminiLiveUrl('gemini-live-test', 'do-not-leak');
  assert.equal(url.includes('do-not-leak'), false);
  assert.equal(new URL(url).searchParams.get('model'), 'models/gemini-live-test');
});
