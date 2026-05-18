function loadFonosterVoiceServer() {
  const voiceSdk = require('@fonoster/voice');
  return voiceSdk.VoiceServer || voiceSdk.default;
}

function createFonosterVoiceServer({
  VoiceServerImpl = null,
  port = 50061,
  skipIdentity = false,
  identityAddress = '',
} = {}) {
  const VoiceServer = VoiceServerImpl || loadFonosterVoiceServer();
  return new VoiceServer({
    port,
    skipIdentity,
    identityAddress,
  });
}

function startFonosterVoiceServer(options = {}) {
  const { app, handler, ...serverOptions } = options;
  const server = createFonosterVoiceServer(serverOptions);
  const listenHandler = handler || buildApplicationHandler(app);
  if (!listenHandler) throw new Error('Fonoster app or handler is required');
  if (typeof server.listen !== 'function') throw new Error('Fonoster VoiceServer.listen is required');

  const started = server.listen(async (request, voice) => {
    const result = await listenHandler(request, voice);
    if (result?.completion && typeof result.completion.then === 'function') {
      await result.completion;
    }
    return result;
  });

  if (started && typeof started.then === 'function') {
    return started.then(() => server);
  }
  return started || server;
}

function buildApplicationHandler(app) {
  if (!app || typeof app.handleCall !== 'function') return null;
  return async (request, voice) => app.handleCall(buildCallFacade(request, voice), request || {});
}

function buildCallFacade(request, voice) {
  if (!voice || typeof voice !== 'object') {
    return { request: request || {}, voice };
  }

  return new Proxy(voice, {
    get(target, prop, receiver) {
      if (prop === 'request') return request || {};
      if (prop === 'voice') return target.voice || target;
      if (prop === 'response') return target;
      const value = Reflect.get(target, prop, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
    set(target, prop, value, receiver) {
      if (prop === 'request' || prop === 'voice') return true;
      return Reflect.set(target, prop, value, receiver);
    },
  });
}

module.exports = { createFonosterVoiceServer, startFonosterVoiceServer };
