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
  assert.equal(new URL(socket.url).searchParams.get('model'), null);
  assert.equal(socket.sent[0].setup.model, 'models/gemini-live-test');
  assert.equal(socket.sent[0].setup.generationConfig.responseModalities[0], 'AUDIO');
  assert.equal(socket.sent[0].setup.generationConfig.temperature, 0.3);
  assert.equal(socket.sent[0].setup.generationConfig.maxOutputTokens, 1024);
  assert.equal(socket.sent[0].setup.realtimeInputConfig.activityHandling, 'NO_INTERRUPTION');
  assert.equal(socket.sent[0].setup.realtimeInputConfig.turnCoverage, 'TURN_INCLUDES_ONLY_ACTIVITY');
  assert.equal(socket.sent[0].setup.realtimeInputConfig.automaticActivityDetection.prefixPaddingMs, 300);
  assert.equal(socket.sent[0].setup.realtimeInputConfig.automaticActivityDetection.silenceDurationMs, 700);
  assert.equal(socket.sent[0].setup.realtimeInputConfig.automaticActivityDetection.startOfSpeechSensitivity, undefined);
  assert.equal(socket.sent[0].setup.realtimeInputConfig.automaticActivityDetection.endOfSpeechSensitivity, undefined);
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
      interrupted: true,
      turnComplete: true
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

test('GeminiLiveClient can opt back into provider start-of-activity interruptions', async () => {
  FakeSocket.instances = [];

  const client = new GeminiLiveClient({
    apiKey: 'secret-token-123',
    model: 'gemini-live-test',
    WebSocketImpl: FakeSocket,
    interruptionMode: 'provider'
  });

  const connectPromise = client.connect();
  const socket = FakeSocket.instances[0];
  socket.open();

  assert.equal(socket.sent[0].setup.realtimeInputConfig.activityHandling, 'START_OF_ACTIVITY_INTERRUPTS');

  socket.receive({ setupComplete: {} });
  await connectPromise;
});

test('GeminiLiveClient buffers streaming transcription chunks until the provider marks them complete', async () => {
  FakeSocket.instances = [];
  const transcripts = [];

  const client = new GeminiLiveClient({
    apiKey: 'secret-token-123',
    model: 'gemini-live-test',
    WebSocketImpl: FakeSocket,
    onTranscript: item => transcripts.push(item)
  });

  const connectPromise = client.connect();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.receive({ setupComplete: {} });
  await connectPromise;

  socket.receive({ serverContent: { outputTranscription: { text: 'Здравствуйте! Чем', finished: false } } });
  socket.receive({ serverContent: { outputTranscription: { text: ' могу помочь?', finished: true } } });
  socket.receive({ serverContent: { inputTranscription: { text: 'Какой у вас ', finished: false } } });
  socket.receive({ serverContent: { inputTranscription: { text: 'слоган?', finished: false }, turnComplete: true } });

  assert.deepEqual(transcripts.map(item => [item.speaker, item.text, item.final]), [
    ['caller', 'Какой у вас слоган?', true],
    ['ai', 'Здравствуйте! Чем могу помочь?', true]
  ]);
});

test('GeminiLiveClient buffers final-marked AI transcription chunks until turnComplete', async () => {
  FakeSocket.instances = [];
  const transcripts = [];

  const client = new GeminiLiveClient({
    apiKey: 'secret-token-123',
    model: 'gemini-live-test',
    WebSocketImpl: FakeSocket,
    maxOutputTokens: 120,
    onTranscript: item => transcripts.push(item)
  });

  const connectPromise = client.connect();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.receive({ setupComplete: {} });
  await connectPromise;

  assert.equal(socket.sent[0].setup.generationConfig.maxOutputTokens, 512);

  socket.receive({ serverContent: { outputTranscription: { text: 'У вас', finished: true } } });
  socket.receive({ serverContent: { outputTranscription: { text: ' есть', finished: true } } });
  assert.deepEqual(transcripts, []);

  socket.receive({ serverContent: { outputTranscription: { text: ' одна сделка.' }, turnComplete: true } });

  assert.deepEqual(transcripts.map(item => [item.speaker, item.text, item.final]), [
    ['ai', 'У вас есть одна сделка.', true]
  ]);
});

test('GeminiLiveClient flushes buffered transcript as final when provider closes the stream', async () => {
  FakeSocket.instances = [];
  const transcripts = [];

  const client = new GeminiLiveClient({
    apiKey: 'secret-token-123',
    model: 'gemini-live-test',
    WebSocketImpl: FakeSocket,
    onTranscript: item => transcripts.push(item)
  });

  const connectPromise = client.connect();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.receive({ setupComplete: {} });
  await connectPromise;

  socket.receive({ serverContent: { inputTranscription: { text: 'Здравствуйте. Один раз ', finished: false } } });
  socket.receive({ serverContent: { inputTranscription: { text: 'два.', finished: false } } });
  socket.close();

  assert.deepEqual(transcripts.map(item => [item.speaker, item.text, item.final]), [
    ['caller', 'Здравствуйте. Один раз два.', true]
  ]);
});

test('buildGeminiLiveUrl uses the base websocket endpoint and never includes API key or model query', () => {
  const url = buildGeminiLiveUrl('gemini-live-test', 'do-not-leak');
  assert.equal(url.includes('do-not-leak'), false);
  assert.equal(new URL(url).searchParams.get('model'), null);
});
