const test = require('node:test');
const assert = require('node:assert/strict');
const { startFonosterVoiceServer } = require('../src/fonoster/server');

class FakeVoice {
  #answerResult = 'answered';

  constructor(id) {
    this.id = id;
  }

  get answered() {
    return this.#answerResult;
  }

  async answer() {
    return this.#answerResult;
  }
}

class FakeVoiceServer {
  static instances = [];

  constructor(config) {
    this.config = config;
    this.listenArgs = null;
    FakeVoiceServer.instances.push(this);
  }

  listen(handler) {
    this.listenArgs = [handler];
    this.handler = handler;
    return this;
  }
}

test('startFonosterVoiceServer wires the real Fonoster listen(handler) shape and awaits call completion', async () => {
  FakeVoiceServer.instances = [];
  let handledCall = null;
  let completionResolved = false;
  const app = {
    async handleCall(call, request) {
      handledCall = { call, request };
      return {
        completion: new Promise(resolve => {
          setImmediate(() => {
            completionResolved = true;
            resolve();
          });
        }),
      };
    },
  };

  const server = startFonosterVoiceServer({
    VoiceServerImpl: FakeVoiceServer,
    port: 51051,
    skipIdentity: true,
    identityAddress: 'identity.test:50051',
    app,
  });

  assert.equal(server, FakeVoiceServer.instances[0]);
  assert.deepEqual(server.config, {
    port: 51051,
    skipIdentity: true,
    identityAddress: 'identity.test:50051',
  });
  assert.equal(typeof server.handler, 'function');

  const request = { appRef: 'voice-app', callRef: 'call-1' };
  const voice = new FakeVoice('voice-response');
  await server.handler(request, voice);

  assert.equal(handledCall.request, request);
  assert.equal(handledCall.call.voice, voice);
  assert.equal(handledCall.call.request, request);
  assert.equal(handledCall.call.id, 'voice-response');
  assert.equal(handledCall.call.answered, 'answered');
  assert.equal(await handledCall.call.answer(), 'answered');
  assert.equal(completionResolved, true);
});
