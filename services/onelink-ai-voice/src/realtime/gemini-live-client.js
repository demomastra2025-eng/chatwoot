class GeminiLiveClient {
  constructor({
    apiKey,
    model = 'gemini-3.1-flash-live-preview',
    voice = 'sulafat',
    language = 'ru-KZ',
    temperature = 0.3,
    maxOutputTokens = 120,
    url = null,
    WebSocketImpl = null,
    setupTimeoutMs = 15_000,
    interruptions = true,
    speechStartSensitivity = 'START_SENSITIVITY_HIGH',
    speechEndSensitivity = 'END_SENSITIVITY_HIGH',
    prefixPaddingMs = 120,
    silenceDurationMs = 300,
    turnCoverage = 'TURN_INCLUDES_ONLY_ACTIVITY',
    onAudio = null,
    onTranscript = null,
    onToolCall = null,
    onInterrupt = null,
    onEvent = null
  } = {}) {
    this.apiKey = apiKey;
    this.model = model;
    this.voice = voice;
    this.language = language;
    this.temperature = temperature;
    this.maxOutputTokens = maxOutputTokens;
    this.speechStartSensitivity = speechStartSensitivity;
    this.speechEndSensitivity = speechEndSensitivity;
    this.prefixPaddingMs = prefixPaddingMs;
    this.silenceDurationMs = silenceDurationMs;
    this.turnCoverage = turnCoverage;
    this.url = url || buildGeminiLiveUrl(model);
    this.WebSocketImpl = WebSocketImpl;
    this.setupTimeoutMs = setupTimeoutMs;
    this.interruptions = interruptions;
    this.onAudio = onAudio;
    this.onTranscript = onTranscript;
    this.onToolCall = onToolCall;
    this.onInterrupt = onInterrupt;
    this.onEvent = onEvent;
    this.socket = null;
    this.socketOpen = false;
    this.setupComplete = false;
    this.closed = false;
    this.pending = [];
  }

  connect(options = {}) {
    this.applyCallbacks(options);
    const WebSocket = this.WebSocketImpl || require('ws');
    this.closed = false;
    this.socketOpen = false;
    this.setupComplete = false;
    this.pending = [];
    this.socket = new WebSocket(this.url, {
      headers: this.apiKey ? { 'x-goog-api-key': this.apiKey } : {}
    });

    return new Promise((resolve, reject) => {
      let settled = false;
      const timeout = this.setupTimeoutMs > 0 ? setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error('Gemini Live setup timeout'));
        }
      }, this.setupTimeoutMs) : null;

      const finish = (fn, value) => {
        if (timeout) clearTimeout(timeout);
        if (!settled) {
          settled = true;
          fn(value);
        }
      };

      this.socket.once('open', () => {
        this.socketOpen = true;
        this.sendSetup(options);
      });

      this.socket.on('message', message => {
        const event = parseJson(message?.toString?.() || String(message));
        if (!event) return;
        this.emitEvent(event);

        if (event.setupComplete && !this.setupComplete) {
          this.setupComplete = true;
          this.flushPending();
          finish(resolve);
        }

        this.handleProviderEvent(event);
      });

      this.socket.once('error', error => {
        this.emitEvent({ error: { message: error?.message || 'Gemini Live websocket error' } });
        finish(reject, error);
      });

      this.socket.once('close', (code, reason) => {
        this.closed = true;
        this.socketOpen = false;
        this.setupComplete = false;
        if (!settled) {
          finish(reject, new Error(`Gemini Live connection closed before setup complete (${code || 'unknown'})`));
        }
        this.emitEvent({ close: { code, reason: reason?.toString?.() || '' } });
      });
    });
  }

  applyCallbacks(options = {}) {
    this.onAudio = options.onAudio || this.onAudio;
    this.onTranscript = options.onTranscript || this.onTranscript;
    this.onToolCall = options.onToolCall || this.onToolCall;
    this.onInterrupt = options.onInterrupt || this.onInterrupt;
    this.onEvent = options.onEvent || this.onEvent;
  }

  sendSetup({ systemPrompt, tools = [] } = {}) {
    const setup = {
      model: normalizeModel(this.model),
      generationConfig: {
        responseModalities: ['AUDIO'],
        temperature: this.temperature,
        maxOutputTokens: this.maxOutputTokens,
        speechConfig: {
          voiceConfig: { prebuiltVoiceConfig: { voiceName: this.voice } },
          ...(this.language ? { languageCode: this.language } : {})
        }
      },
      realtimeInputConfig: {
        automaticActivityDetection: {
          disabled: false,
          startOfSpeechSensitivity: this.speechStartSensitivity,
          endOfSpeechSensitivity: this.speechEndSensitivity,
          prefixPaddingMs: this.prefixPaddingMs,
          silenceDurationMs: this.silenceDurationMs
        },
        activityHandling: this.interruptions ? 'START_OF_ACTIVITY_INTERRUPTS' : 'NO_INTERRUPTION',
        turnCoverage: this.turnCoverage
      },
      inputAudioTranscription: {},
      outputAudioTranscription: {}
    };

    if (systemPrompt) {
      setup.systemInstruction = { parts: [{ text: systemPrompt }] };
    }

    const normalizedTools = normalizeTools(tools);
    if (normalizedTools.length) {
      setup.tools = normalizedTools;
    }

    this.sendNow({ setup });
  }

  sendAudio(data, { mimeType = 'audio/pcm;rate=16000' } = {}) {
    const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data || []);
    this.enqueueOrSend({
      realtimeInput: {
        audio: {
          data: buffer.toString('base64'),
          mimeType
        }
      }
    });
  }

  sendText(text) {
    if (!text) return;
    this.enqueueOrSend({ realtimeInput: { text: String(text) } });
  }

  interrupt() {
    this.enqueueOrSend({ realtimeInput: { activityStart: {} } });
  }

  sendToolResponse(id, response, name = undefined) {
    this.enqueueOrSend({
      toolResponse: {
        functionResponses: [{ id, ...(name ? { name } : {}), response }]
      }
    });
  }

  sendNow(payload) {
    if (!this.socket || this.socket.readyState !== 1) {
      throw new Error('Gemini Live websocket is not open');
    }
    this.socket.send(JSON.stringify(payload));
  }

  enqueueOrSend(payload) {
    if (this.closed) return;
    if (!this.socketOpen || !this.setupComplete || !this.socket || this.socket.readyState !== 1) {
      this.pending.push(payload);
      return;
    }
    this.sendNow(payload);
  }

  flushPending() {
    while (this.pending.length > 0 && this.socket?.readyState === 1 && this.setupComplete) {
      this.sendNow(this.pending.shift());
    }
  }

  handleProviderEvent(event) {
    if (event.serverContent) {
      this.handleServerContent(event.serverContent);
    }
    if (event.toolCall) {
      void this.handleToolCall(event.toolCall);
    }
    if (event.toolCallCancellation) {
      this.emitEvent({ toolCallCancellation: event.toolCallCancellation });
    }
  }

  handleServerContent(serverContent) {
    const inputText = trimText(serverContent.inputTranscription?.text);
    if (inputText) {
      this.onTranscript?.({ speaker: 'caller', text: inputText, provider: 'gemini-live', final: true });
    }

    const outputText = trimText(serverContent.outputTranscription?.text);
    if (outputText) {
      this.onTranscript?.({ speaker: 'ai', text: outputText, provider: 'gemini-live', final: true });
    }

    if (serverContent.interrupted) {
      this.onInterrupt?.({
        provider: 'gemini-live',
        source: 'serverContent.interrupted',
        reason: serverContent.interruptionReason || serverContent.reason || 'vad_or_caller_speech'
      });
    }

    const parts = serverContent.modelTurn?.parts || [];
    for (const part of parts) {
      const inlineData = part.inlineData || part.inline_data;
      const data = inlineData?.data;
      if (!data) continue;
      const mimeType = inlineData.mimeType || inlineData.mime_type || 'audio/pcm';
      if (!String(mimeType).startsWith('audio/pcm')) continue;
      this.onAudio?.(Buffer.from(data, 'base64'), { mimeType, provider: 'gemini-live' });
    }
  }

  async handleToolCall(toolCall) {
    const functionCalls = Array.isArray(toolCall.functionCalls) ? toolCall.functionCalls : [];
    if (!functionCalls.length || !this.onToolCall) return;

    const responses = [];
    for (const call of functionCalls) {
      const name = trimText(call.name);
      const id = trimText(call.id) || name;
      try {
        const response = await this.onToolCall({ id, name, args: call.args || {} });
        responses.push({ id, name, response });
      } catch (error) {
        responses.push({ id, name, response: { ok: false, error: sanitizeErrorMessage(error?.message || 'tool execution failed') } });
      }
    }

    this.enqueueOrSend({
      toolResponse: {
        functionResponses: responses.map(({ id, name, response }) => ({ id, name, response }))
      }
    });
  }

  emitEvent(event) {
    try {
      this.onEvent?.(event);
    } catch (_error) {
      // Diagnostics callbacks must never break realtime media handling.
    }
  }

  close() {
    if (this.closed) return;
    try {
      this.enqueueOrSend({ realtimeInput: { audioStreamEnd: true } });
      this.closed = true;
      if (this.socket) this.socket.close();
    } catch (_error) {
      this.closed = true;
    }
  }
}

function buildGeminiLiveUrl(_model) {
  return 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
}

function normalizeModel(model) {
  const raw = String(model || 'gemini-3.1-flash-live-preview').replace(/^models\//, '');
  return `models/${raw}`;
}

function normalizeTools(tools) {
  const declarations = (Array.isArray(tools) ? tools : [])
    .filter(tool => tool && tool.name)
    .map(tool => ({
      name: String(tool.name),
      description: tool.description || tool.summary || `OneLink tool ${tool.name}`,
      parameters: tool.parameters || tool.schema || { type: 'object', properties: {} }
    }));

  return declarations.length ? [{ functionDeclarations: declarations }] : [];
}

function parseJson(raw) {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch (_error) {
    return null;
  }
}

function trimText(value) {
  return String(value || '').trim();
}

function sanitizeErrorMessage(message) {
  return String(message || 'request failed').replace(/(key|token|secret|password)=([^\s&]+)/gi, '$1=[REDACTED]');
}

module.exports = { GeminiLiveClient, buildGeminiLiveUrl, normalizeTools, normalizeModel };
