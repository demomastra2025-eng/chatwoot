/* eslint-disable max-classes-per-file, class-methods-use-this */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  attachMock,
  janusDestroyMock,
  pluginDetachMock,
  pluginSendMock,
  pluginHangupMock,
  pluginState,
  pluginHandleState,
  janusState,
  janusAiMediaBridgeInstances,
  rejectIncomingCallMock,
  uploadRecordingMock,
  updatePresenceMock,
  updatePresenceOnUnloadMock,
} = vi.hoisted(() => ({
  attachMock: vi.fn(),
  janusDestroyMock: vi.fn(),
  pluginDetachMock: vi.fn(),
  pluginSendMock: vi.fn(),
  pluginHangupMock: vi.fn(),
  pluginState: { options: null },
  pluginHandleState: {
    createOfferImplementation: null,
    createAnswerImplementation: null,
  },
  janusState: { autoConnect: true, instances: [] },
  janusAiMediaBridgeInstances: [],
  rejectIncomingCallMock: vi.fn(() => Promise.resolve({})),
  uploadRecordingMock: vi.fn(() => Promise.resolve({})),
  updatePresenceMock: vi.fn(() =>
    Promise.resolve({
      presence_update_accepted: true,
      registered_for_routing: true,
    })
  ),
  updatePresenceOnUnloadMock: vi.fn(() => Promise.resolve(null)),
}));

vi.mock('webrtc-adapter', () => ({
  default: { browserDetails: { browser: 'chrome' } },
  browserDetails: { browser: 'chrome' },
}));

vi.mock('janus-gateway', () => {
  class JanusMock {
    constructor(options = {}) {
      this.options = options;
      janusState.instances.push(this);
      if (janusState.autoConnect) {
        window.setTimeout(() => options.success?.(), 0);
      }
    }

    attach(options = {}) {
      this.pluginOptions = options;
      pluginState.options = options;
      attachMock(options);
      options.success?.({
        send: pluginSendMock,
        detach: pluginDetachMock,
        hangup: pluginHangupMock,
        createOffer: offerOptions => {
          if (pluginHandleState.createOfferImplementation) {
            pluginHandleState.createOfferImplementation(offerOptions);
            return;
          }
          offerOptions?.success?.({ type: 'offer', sdp: 'mock-sdp' });
        },
        createAnswer: answerOptions => {
          if (pluginHandleState.createAnswerImplementation) {
            pluginHandleState.createAnswerImplementation(answerOptions);
            return;
          }
          const { success } = answerOptions || {};
          success?.({ type: 'answer', sdp: 'mock-answer-sdp' });
        },
      });
    }

    destroy() {
      janusDestroyMock();
      this.options.destroyed?.();
    }
  }

  JanusMock.initDone = false;
  JanusMock.init = vi.fn(({ callback }) => {
    JanusMock.initDone = true;
    callback?.();
  });
  JanusMock.attachMediaStream = vi.fn((element, stream) => {
    element.srcObject = stream;
  });

  return { default: JanusMock };
});

vi.mock('./voiceAPIClient', () => ({
  default: {
    rejectIncomingCall: rejectIncomingCallMock,
    uploadWebphoneRecording: uploadRecordingMock,
    updateWebphonePresence: updatePresenceMock,
    updateWebphonePresenceOnUnload: updatePresenceOnUnloadMock,
  },
}));

vi.mock('./janusAiMediaBridge', () => ({
  default: class JanusAiMediaBridgeMock {
    constructor(options = {}) {
      this.options = options;
      this.attachRemoteStream = vi.fn();
      this.close = vi.fn();
      janusAiMediaBridgeInstances.push(this);
    }

    start() {
      return Promise.resolve(this);
    }

    outputTrack() {
      return { id: 'ai-output-track', kind: 'audio' };
    }
  },
}));

import JanusSipVoiceClient, {
  JanusSipVoiceClient as JanusSipVoiceClientClass,
  createJanusSipVoiceClient,
} from './janusSipVoiceClient';

let audioPlaySpy;

const sipuniSession = {
  provider: 'sipuni',
  callingSupported: true,
  janusServer: 'wss://dev.one-link.kz/janus-sipuni',
  recordingStrategy: 'provider_api',
  recordingFallbackStrategy: 'browser_fallback',
  sip: {
    username: '990001000018',
    password: 'test-sip-password',
    host: 'ats01.kz.sipuni.com',
    internalExtension: '502',
  },
};

const binotelSession = {
  ...sipuniSession,
  provider: 'binotel',
  sip: {
    username: 'pq4dyw5f',
    password: 'test-binotel-password',
    host: 'sip53.binotel.com',
    internalExtension: '901',
  },
};

const asteriskAnalogSession = {
  ...sipuniSession,
  provider: 'asterisk_analog',
  sip: {
    username: '9098',
    password: 'test-asterisk-password',
    host: '10.77.0.2',
    internalExtension: '9098',
  },
};

const asteriskServerRecordingSession = {
  ...asteriskAnalogSession,
  accountId: 530,
  sipProfileId: 77,
  recordingStrategy: 'janus_server',
  recordingFallbackStrategy: 'browser_fallback',
  janusRecording: {
    enabled: true,
    filenamePrefix: 'janus-prod_asterisk_account_530_profile_77',
    audio: true,
    peerAudio: true,
  },
};

const flushJanusInitialization = async () => {
  for (let index = 0; index < 3; index += 1) {
    // Janus connect and SIP registered are delivered on separate timer turns.
    // eslint-disable-next-line no-await-in-loop
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });
  }
};

const fakeAudioTrack = id => ({
  id,
  kind: 'audio',
  readyState: 'live',
  stop: vi.fn(),
});

const installRecordingMocks = ({ stopImmediately = true } = {}) => {
  const createdDestinations = [];
  const createdSources = [];
  const createdGains = [];
  const original = {
    AudioContext: window.AudioContext,
    MediaRecorder: window.MediaRecorder,
    MediaStream: window.MediaStream,
  };

  function MediaStreamMock(tracks = []) {
    this.tracks = tracks;
  }

  MediaStreamMock.prototype.getTracks = function getTracks() {
    return this.tracks;
  };

  MediaStreamMock.prototype.getAudioTracks = function getAudioTracks() {
    return this.tracks.filter(track => track.kind === 'audio');
  };

  function AudioContextMock() {}

  AudioContextMock.prototype.createMediaStreamDestination =
    function createMediaStreamDestination() {
      const destination = { stream: new MediaStreamMock() };
      createdDestinations.push(destination);
      return destination;
    };

  AudioContextMock.prototype.createMediaStreamSource =
    function createMediaStreamSource() {
      const source = { connect: vi.fn() };
      createdSources.push(source);
      return source;
    };

  AudioContextMock.prototype.createGain = function createGain() {
    const gain = {
      gain: { value: 1 },
      connect: vi.fn(),
    };
    createdGains.push(gain);
    return gain;
  };

  AudioContextMock.prototype.close = function close() {
    return Promise.resolve();
  };

  function MediaRecorderMock(stream, options = {}) {
    this.stream = stream;
    this.mimeType = options.mimeType || 'audio/webm';
    this.audioBitsPerSecond = options.audioBitsPerSecond;
    this.state = 'inactive';
    MediaRecorderMock.instances.push(this);
  }

  MediaRecorderMock.instances = [];
  MediaRecorderMock.isTypeSupported = vi.fn(
    type => type === 'audio/webm;codecs=opus'
  );

  MediaRecorderMock.prototype.start = function start() {
    this.state = 'recording';
  };

  MediaRecorderMock.prototype.flushStop = function flushStop() {
    this.ondataavailable?.({
      data: new Blob(['janus-audio'], { type: this.mimeType }),
    });
    this.onstop?.();
  };

  MediaRecorderMock.prototype.stop = function stop() {
    this.state = 'inactive';
    if (stopImmediately) this.flushStop();
  };

  window.AudioContext = AudioContextMock;
  window.MediaRecorder = MediaRecorderMock;
  window.MediaStream = MediaStreamMock;

  return {
    createdDestinations,
    createdGains,
    createdSources,
    MediaRecorderMock,
    restore: () => {
      window.AudioContext = original.AudioContext;
      window.MediaRecorder = original.MediaRecorder;
      window.MediaStream = original.MediaStream;
    },
  };
};

describe('janusSipVoiceClient', () => {
  beforeEach(async () => {
    audioPlaySpy = vi
      .spyOn(window.HTMLMediaElement.prototype, 'play')
      .mockImplementation(() => Promise.resolve());
    pluginSendMock.mockImplementation(({ message } = {}) => {
      if (message?.request === 'register') {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({ result: { event: 'registered' } });
        }, 0);
      }
      if (message?.request === 'call') {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({
            result: { event: 'calling', call_id: 'outbound-call-id' },
          });
        }, 0);
      }
    });
    await JanusSipVoiceClient.destroyDevice();
    janusState.autoConnect = true;
    janusState.instances.length = 0;
    attachMock.mockClear();
    janusDestroyMock.mockClear();
    pluginDetachMock.mockClear();
    pluginSendMock.mockClear();
    pluginHangupMock.mockClear();
    pluginHandleState.createOfferImplementation = null;
    pluginHandleState.createAnswerImplementation = null;
    janusAiMediaBridgeInstances.length = 0;
    rejectIncomingCallMock.mockClear();
    uploadRecordingMock.mockClear();
    updatePresenceMock.mockClear();
    updatePresenceOnUnloadMock.mockClear();
  });

  afterEach(async () => {
    await JanusSipVoiceClient.destroyDevice();
    audioPlaySpy?.mockRestore();
    vi.useRealTimers();
  });

  it('fences a Janus connect callback that arrives after destroy', async () => {
    const client = createJanusSipVoiceClient();
    janusState.autoConnect = false;

    const initialization = client.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    await vi.waitFor(() => {
      expect(janusState.instances).toHaveLength(1);
    });

    await client.destroyDevice();
    janusState.instances[0].options.success();

    await expect(initialization).rejects.toThrow('stale_janus_session');
    expect(client.janus).toBeNull();
    expect(client.sipHandle).toBeNull();
    expect(attachMock).not.toHaveBeenCalled();
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
  });

  it('fences a Janus connect callback after an unexpected pre-connect destroy', async () => {
    const client = createJanusSipVoiceClient();
    janusState.autoConnect = false;

    const initialization = client.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    await vi.waitFor(() => {
      expect(janusState.instances).toHaveLength(1);
    });

    janusState.instances[0].options.destroyed();
    janusState.instances[0].options.success();

    await expect(initialization).rejects.toThrow('janus_destroyed');
    expect(client.janus).toBeNull();
    expect(client.sipHandle).toBeNull();
    expect(attachMock).not.toHaveBeenCalled();
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
  });

  it('reports the previous inbox offline before registering the next inbox', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });

    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );
    updatePresenceMock.mockClear();

    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4770,
    });

    expect(updatePresenceMock.mock.calls).toEqual([
      [
        false,
        expect.objectContaining({
          inboxId: 4769,
          context: expect.objectContaining({
            registration_instance_id: expect.any(String),
          }),
        }),
      ],
      [true, expect.objectContaining({ inboxId: 4770 })],
    ]);
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
    expect(pluginDetachMock).toHaveBeenCalledTimes(1);
  });

  it('releases the browser registration lease with a keepalive request on page unload', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    updatePresenceMock.mockClear();

    await JanusSipVoiceClient.destroyDevice({ keepalivePresence: true });
    await vi.waitFor(() => {
      expect(updatePresenceOnUnloadMock).toHaveBeenCalledWith(
        false,
        expect.objectContaining({
          inboxId: 4769,
          context: expect.objectContaining({
            registration_instance_id: expect.any(String),
          }),
        })
      );
    });
    expect(updatePresenceMock).not.toHaveBeenCalled();
  });

  it('sends offline presence only after an in-flight online report settles', async () => {
    const client = createJanusSipVoiceClient();
    let resolveOnlinePresence;
    updatePresenceMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOnlinePresence = resolve;
        })
    );

    const initialization = client.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    await flushJanusInitialization();
    const destruction = client.destroyDevice();

    expect(updatePresenceMock).toHaveBeenCalledTimes(1);
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );

    resolveOnlinePresence?.({
      presence_update_accepted: true,
      registered_for_routing: true,
    });
    await initialization.catch(() => null);
    await destruction;
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });

    expect(updatePresenceMock).toHaveBeenCalledTimes(2);
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      false,
      expect.objectContaining({
        inboxId: 4769,
        context: expect.objectContaining({
          registration_instance_id: expect.any(String),
        }),
      })
    );
  });

  it('preserves a pending incoming call when the Janus websocket ticket rotates', async () => {
    const client = createJanusSipVoiceClient();
    await client.initializeDevice(
      {
        ...sipuniSession,
        janusServer:
          'wss://dev.one-link.kz/janus-sipuni?janus_ticket=initial-ticket',
      },
      { inboxId: 4769 }
    );
    pluginState.options?.onmessage?.(
      {
        result: {
          event: 'incomingcall',
          call_id: 'janus-invite-ticket-refresh',
          username: 'sip:+77000000000@ats01.kz.sipuni.com',
        },
      },
      { type: 'offer', sdp: 'remote-offer-sdp' }
    );
    janusDestroyMock.mockClear();
    pluginDetachMock.mockClear();

    await client.initializeDevice(
      {
        ...sipuniSession,
        janusServer:
          'wss://dev.one-link.kz/janus-sipuni?janus_ticket=refreshed-ticket',
      },
      { inboxId: 4769 }
    );

    expect(janusState.instances).toHaveLength(1);
    expect(janusDestroyMock).not.toHaveBeenCalled();
    expect(pluginDetachMock).not.toHaveBeenCalled();
    expect(
      client.hasPendingIncomingCall({
        callRef: 'janus-invite-ticket-refresh',
        strict: true,
      })
    ).toBe(true);
    expect(client.sessionConfig.janusServer).toContain(
      'janus_ticket=refreshed-ticket'
    );
  });

  it('recreates the Janus SIP registration when the profile registration version changes', async () => {
    await JanusSipVoiceClient.initializeDevice(
      { ...sipuniSession, registrationConfigVersion: 'version-1' },
      {
        inboxId: 4769,
      }
    );

    attachMock.mockClear();
    janusDestroyMock.mockClear();
    pluginDetachMock.mockClear();
    pluginSendMock.mockClear();
    updatePresenceMock.mockClear();

    await JanusSipVoiceClient.initializeDevice(
      { ...sipuniSession, registrationConfigVersion: 'version-2' },
      {
        inboxId: 4769,
      }
    );

    const requests = pluginSendMock.mock.calls.map(
      ([payload]) => payload?.message?.request
    );
    expect(requests).toEqual(['unregister', 'register']);
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
    expect(pluginDetachMock).toHaveBeenCalledTimes(1);
    expect(attachMock).toHaveBeenCalledTimes(1);
    expect(updatePresenceMock).toHaveBeenCalledWith(
      false,
      expect.objectContaining({
        inboxId: 4769,
        context: expect.objectContaining({
          registration_config_version: 'version-1',
        }),
      })
    );
    expect(updatePresenceMock).toHaveBeenCalledWith(
      true,
      expect.objectContaining({
        inboxId: 4769,
        context: expect.objectContaining({
          registration_config_version: 'version-2',
        }),
      })
    );
  });

  it('unregisters the browser SIP device when backend rejects a stale registration context', async () => {
    const client = createJanusSipVoiceClient();
    const unregisteredHandler = vi.fn();
    let resolvePresence;
    updatePresenceMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolvePresence = resolve;
        })
    );
    client.addEventListener('call:unregistered', unregisteredHandler);

    const initialization = client.initializeDevice(
      { ...sipuniSession, registrationConfigVersion: 'version-1' },
      {
        inboxId: 4769,
      }
    );
    await flushJanusInitialization();

    pluginSendMock.mockClear();
    resolvePresence?.({
      presence_update_accepted: false,
      reason: 'sip_profile_registration_context_mismatch',
      registered_for_routing: false,
    });
    await expect(initialization).rejects.toThrow(
      'sip_profile_registration_context_mismatch'
    );
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });

    expect(client.registered).toBe(false);
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      false,
      expect.objectContaining({ inboxId: 4769 })
    );
    expect(unregisteredHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          reason: 'sip_profile_registration_context_mismatch',
        }),
      })
    );
  });

  it('unregisters the browser SIP device when backend no longer routes the presence', async () => {
    const client = createJanusSipVoiceClient();
    let resolvePresence;
    updatePresenceMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolvePresence = resolve;
        })
    );

    const initialization = client.initializeDevice(
      { ...sipuniSession, registrationConfigVersion: 'version-1' },
      {
        inboxId: 4769,
      }
    );
    await flushJanusInitialization();

    pluginSendMock.mockClear();
    resolvePresence?.({
      presence_update_accepted: false,
      reason: 'agent_binding_missing',
      calling_supported: false,
      registered_for_routing: false,
    });
    await expect(initialization).rejects.toThrow('agent_binding_missing');
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });

    expect(client.registered).toBe(false);
  });

  it('keeps Binotel as the active provider for Janus SIP sessions', async () => {
    const state = await JanusSipVoiceClient.initializeDevice(binotelSession, {
      inboxId: 4769,
    });

    expect(state).toEqual(
      expect.objectContaining({
        provider: 'binotel',
        callingSupported: true,
        registered: true,
        internalExtension: '901',
      })
    );
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );
  });

  it('deduplicates parallel Janus SIP initialization for the same profile', async () => {
    const client = createJanusSipVoiceClient();

    const [firstSession, secondSession] = await Promise.all([
      client.initializeDevice(sipuniSession, { inboxId: 4769 }),
      client.initializeDevice(sipuniSession, { inboxId: 4769 }),
    ]);

    expect(firstSession).toEqual(secondSession);
    expect(attachMock).toHaveBeenCalledTimes(1);
    expect(pluginSendMock).toHaveBeenCalledTimes(1);
    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
        }),
      })
    );
  });

  it('refreshes the backend presence lease independently from SIP REGISTER', async () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.sipHandle = { send: pluginSendMock };
    client.registered = true;
    client.inboxId = 4769;
    pluginSendMock.mockClear();
    updatePresenceMock.mockClear();

    await client.refreshPresenceRegistration();

    expect(pluginSendMock).not.toHaveBeenCalled();
    expect(updatePresenceMock).toHaveBeenCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );
  });

  it('clears the SIP timeout on Janus ACK before a slow Rails presence lease completes', async () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.sipHandle = { send: pluginSendMock };
    client.inboxId = 4769;
    let resolvePresence;
    updatePresenceMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolvePresence = resolve;
      })
    );
    client.registrationTimer = window.setTimeout(() => {}, 8_000);

    const registrationAck = client.completeRegistration(
      { username: 'sip:1001@sip.example.com' },
      {}
    );

    expect(client.registrationTimer).toBeNull();
    expect(client.registered).toBe(false);

    resolvePresence({
      presence_update_accepted: true,
      registered_for_routing: true,
    });
    await registrationAck;
    expect(client.registered).toBe(true);
  });

  it('fails registration when the Rails routing lease confirmation never settles', async () => {
    vi.useFakeTimers();
    const client = createJanusSipVoiceClient();
    const registrationReject = vi.fn();
    const unregisteredHandler = vi.fn();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    const staleHandle = { detach: vi.fn(), send: pluginSendMock };
    const staleJanus = { destroy: vi.fn() };
    client.sipHandle = staleHandle;
    client.janus = staleJanus;
    client.inboxId = 4769;
    client.registrationReject = registrationReject;
    client.addEventListener('call:unregistered', unregisteredHandler);
    updatePresenceMock
      .mockImplementationOnce(() => new Promise(() => {}))
      .mockResolvedValueOnce({
        presence_update_accepted: true,
        registered_for_routing: false,
      });

    try {
      const registrationAck = client.completeRegistration(
        { username: 'sip:1001@sip.example.com' },
        {}
      );
      await vi.advanceTimersByTimeAsync(15_000);
      await registrationAck;

      expect(client.registered).toBe(false);
      expect(registrationReject).toHaveBeenCalledWith(
        expect.objectContaining({
          message: 'presence_confirmation_timeout',
          reason: 'presence_confirmation_timeout',
        })
      );
      expect(unregisteredHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            reason: 'presence_confirmation_timeout',
          }),
        })
      );
      expect(updatePresenceMock).toHaveBeenLastCalledWith(
        false,
        expect.objectContaining({ inboxId: 4769 })
      );
      expect(client.registrationTimedOut).toBe(true);
      expect(client.sipHandle).toBeNull();
      expect(client.janus).toBeNull();
      expect(staleHandle.detach).toHaveBeenCalled();
      expect(staleJanus.destroy).toHaveBeenCalled();

      const presenceCallCount = updatePresenceMock.mock.calls.length;
      await client.completeRegistration(
        { username: 'sip:1001@sip.example.com' },
        {}
      );
      expect(client.registered).toBe(false);
      expect(updatePresenceMock).toHaveBeenCalledTimes(presenceCallCount);
    } finally {
      vi.useRealTimers();
    }
  });

  it('rejects a late presence confirmation after its transport generation is retired', async () => {
    const client = createJanusSipVoiceClient();
    let resolvePresence;
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.sipHandle = { send: pluginSendMock };
    client.janus = {};
    client.inboxId = 4769;
    updatePresenceMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolvePresence = resolve;
        })
    );

    const registration = client.markRegistered();
    client.registrationTimedOut = true;
    client.janusGeneration += 1;
    client.sipHandleGeneration += 1;
    resolvePresence({
      presence_update_accepted: true,
      registered_for_routing: true,
    });

    await expect(registration).rejects.toThrow('stale_presence_confirmation');
    expect(client.registered).toBe(false);
    expect(client.presenceHeartbeatTimer).toBeNull();
  });

  it('does not force a SIP REGISTER refresh while the Janus registration is healthy', async () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.janus = {};
    client.sipHandle = { send: pluginSendMock };
    client.initialized = true;
    client.registered = true;
    const ensureRegisteredSpy = vi.spyOn(client, 'ensureRegistered');

    await client.recoverRegistrationAfterCall();

    expect(ensureRegisteredSpy).not.toHaveBeenCalled();
    expect(pluginSendMock).not.toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
        }),
      })
    );
  });

  it('drops routing after two consecutive Rails heartbeat failures', async () => {
    const client = createJanusSipVoiceClient();
    const unregisteredHandler = vi.fn();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.janus = {};
    client.sipHandle = {};
    client.registered = true;
    client.registrationInstanceId = 'registration-heartbeat';
    client.inboxId = 4769;
    client.addEventListener('call:unregistered', unregisteredHandler);
    updatePresenceMock.mockRejectedValue(new Error('rails_unavailable'));

    await client.refreshPresenceRegistration();
    expect(client.registered).toBe(true);

    await client.refreshPresenceRegistration();
    expect(client.registered).toBe(false);
    expect(unregisteredHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          reason: 'presence_heartbeat_failed',
        }),
      })
    );
  });

  it('does not schedule an application-level SIP REGISTER refresh', async () => {
    vi.useFakeTimers();
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.registered = true;
    client.inboxId = 4769;
    const sipRefreshSpy = vi.spyOn(client, 'refreshSipRegistration');

    client.startPresenceHeartbeat();
    await vi.advanceTimersByTimeAsync(120_000);

    expect(sipRefreshSpy).not.toHaveBeenCalled();
    expect(updatePresenceMock).toHaveBeenCalled();
    client.stopPresenceHeartbeat();
    vi.useRealTimers();
  });

  it('supports an explicit SIP REGISTER refresh for recovery', async () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.janus = {};
    client.sipHandle = { send: pluginSendMock };
    client.registered = true;
    client.inboxId = 4769;
    pluginSendMock.mockClear();

    const refresh = client.refreshSipRegistration();
    client.handleSipMessage({ result: { event: 'registered' } });
    await refresh;

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
        }),
      })
    );
  });

  it('drops routing immediately when Janus reports SIP unregistered', () => {
    const client = createJanusSipVoiceClient();
    const unregisteredHandler = vi.fn();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.registered = true;
    client.inboxId = 4769;
    client.addEventListener('call:unregistered', unregisteredHandler);

    client.handleSipMessage({
      result: { event: 'unregistered', code: 200, reason: 'OK' },
    });

    expect(client.registered).toBe(false);
    expect(unregisteredHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          reason: 'OK',
          sipCode: 200,
        }),
      })
    );
  });

  it('delegates a stale SIP refresh to outer fresh-ticket recovery', async () => {
    const client = createJanusSipVoiceClient();
    const unregisteredHandler = vi.fn();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.janus = {};
    client.sipHandle = { send: pluginSendMock };
    client.initialized = true;
    client.registered = true;
    client.inboxId = 4769;
    client.addEventListener('call:unregistered', unregisteredHandler);
    pluginSendMock.mockImplementationOnce(() => {
      window.setTimeout(() => {
        client.handleSipMessage({ error: 'Wrong state (not registered)' });
      }, 0);
    });
    updatePresenceMock.mockClear();

    await client.refreshSipRegistration();

    expect(pluginSendMock).toHaveBeenCalledTimes(1);
    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
        }),
      })
    );
    expect(unregisteredHandler).toHaveBeenCalled();
  });

  it('does not let a failed stale SIP refresh unregister a newer generation', async () => {
    const client = createJanusSipVoiceClient();
    const unregisteredHandler = vi.fn();
    let rejectRefresh;
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.janus = {};
    client.sipHandle = {};
    client.registered = true;
    client.registrationInstanceId = 'registration-old';
    client.inboxId = 4769;
    client.ensureRegistered = vi.fn(
      () =>
        new Promise((_, reject) => {
          rejectRefresh = reject;
        })
    );
    client.addEventListener('call:unregistered', unregisteredHandler);

    const refresh = client.refreshSipRegistration();
    client.janusGeneration += 1;
    client.sipHandleGeneration += 1;
    client.registrationInstanceId = 'registration-new';
    client.registered = true;
    rejectRefresh(new Error('stale_refresh_failed'));
    await refresh;

    expect(client.registered).toBe(true);
    expect(client.registrationInstanceId).toBe('registration-new');
    expect(unregisteredHandler).not.toHaveBeenCalled();
  });

  it('ignores late Janus registration events after the registration timeout', async () => {
    vi.useFakeTimers();
    const client = createJanusSipVoiceClient();
    const registeredHandler = vi.fn();
    client.addEventListener('call:registered', registeredHandler);
    pluginSendMock.mockImplementation(() => {});

    try {
      const result = client
        .initializeDevice(binotelSession, { inboxId: 4769 })
        .catch(error => error);

      await vi.advanceTimersByTimeAsync(0);
      const timedOutHandleMessage = pluginState.options?.onmessage;
      const janusGeneration = client.janusGeneration;
      const sipHandleGeneration = client.sipHandleGeneration;
      await vi.advanceTimersByTimeAsync(8000);

      const error = await result;
      expect(error).toBeInstanceOf(Error);
      expect(error.message).toBe('sip_registration_timeout');
      expect(updatePresenceMock).toHaveBeenLastCalledWith(
        false,
        expect.objectContaining({ inboxId: 4769 })
      );
      expect(client.sipHandle).toBeNull();
      expect(client.janus).toBeNull();
      expect(client.initialized).toBe(false);
      expect(client.sipHandleGeneration).toBeGreaterThan(sipHandleGeneration);
      expect(client.janusGeneration).toBeGreaterThan(janusGeneration);
      expect(pluginDetachMock).toHaveBeenCalled();
      expect(janusDestroyMock).toHaveBeenCalled();
      await expect(client.ensureRegistered()).rejects.toThrow(
        'sip_device_not_ready'
      );

      updatePresenceMock.mockClear();
      timedOutHandleMessage?.({ result: { event: 'registered' } });

      expect(client.sessionState().registered).toBe(false);
      expect(registeredHandler).not.toHaveBeenCalled();
      expect(updatePresenceMock).not.toHaveBeenCalledWith(
        true,
        expect.objectContaining({ inboxId: 4769 })
      );
    } finally {
      vi.useRealTimers();
      await client.destroyDevice();
    }
  });

  it('does not hang up a newer call when cleanup carries a stale call reference', async () => {
    const client = createJanusSipVoiceClient();
    client.sipHandle = {
      send: pluginSendMock,
      hangup: pluginHangupMock,
    };
    client.currentCallRef = 'provider-call-b';
    client.currentJanusCallId = 'janus-call-b';
    client.hasActiveCall = true;

    const result = await client.endClientCall({
      callRef: 'provider-call-a',
      janusCallRef: 'janus-call-a',
    });

    expect(result).toBeNull();
    expect(pluginSendMock).not.toHaveBeenCalled();
    expect(pluginHangupMock).not.toHaveBeenCalled();
    expect(client.currentCallRef).toBe('provider-call-b');
    expect(client.hasActiveCall).toBe(true);
  });

  it('accepts a valid cleanup when every supplied authoritative alias matches', async () => {
    const client = createJanusSipVoiceClient();
    client.sipHandle = {
      send: pluginSendMock,
      hangup: pluginHangupMock,
    };
    client.currentCallRef = 'provider-call-a';
    client.currentJanusCallId = 'janus-call-a';
    client.hasActiveCall = true;

    await client.endClientCall({
      callRef: 'provider-call-a',
      janusCallRef: 'janus-call-a',
    });

    expect(pluginSendMock).toHaveBeenCalledWith({
      message: { request: 'hangup' },
    });
    expect(pluginHangupMock).toHaveBeenCalled();
  });

  it('accepts outbound cleanup when the Janus alias is stored on the active attempt', async () => {
    const client = createJanusSipVoiceClient();
    client.sipHandle = {
      send: pluginSendMock,
      hangup: pluginHangupMock,
    };
    client.currentCallRef = 'provider-call-a';
    client.currentJanusCallId = null;
    client.outboundAttempt = {
      callRef: 'provider-call-a',
      handle: client.sipHandle,
      janusCallId: 'janus-call-a',
      sipCallSent: true,
      startSettled: true,
      audioTrack: null,
      timer: null,
    };
    client.hasActiveCall = true;

    await client.endClientCall({
      callRef: 'provider-call-a',
      janusCallRef: 'janus-call-a',
    });

    expect(pluginSendMock).toHaveBeenCalledWith({
      message: { request: 'hangup' },
    });
    expect(pluginHangupMock).toHaveBeenCalled();
  });

  it('rejects mixed aliases even when one alias belongs to the active call', async () => {
    const client = createJanusSipVoiceClient();
    client.sipHandle = {
      send: pluginSendMock,
      hangup: pluginHangupMock,
    };
    client.currentCallRef = 'provider-call-b';
    client.currentJanusCallId = 'janus-call-b';
    client.hasActiveCall = true;

    const result = await client.endClientCall({
      callRef: 'provider-call-a',
      janusCallRef: 'janus-call-b',
    });

    expect(result).toBeNull();
    expect(pluginSendMock).not.toHaveBeenCalled();
    expect(pluginHangupMock).not.toHaveBeenCalled();
  });

  it('does not decline a newer pending INVITE for a stale loser call', async () => {
    const client = createJanusSipVoiceClient();
    client.sipHandle = {
      send: pluginSendMock,
      hangup: pluginHangupMock,
    };
    client.pendingIncomingCall = {
      callId: 'janus-call-b',
      result: { call_id: 'janus-call-b' },
    };
    client.currentCallRef = 'provider-call-b';

    const result = await client.rejectIncomingCall({
      callRef: 'provider-call-a',
      janusCallRef: 'janus-call-a',
    });

    expect(result).toBeNull();
    expect(pluginSendMock).not.toHaveBeenCalled();
    expect(pluginHangupMock).not.toHaveBeenCalled();
    expect(client.pendingIncomingCall?.callId).toBe('janus-call-b');
  });

  it('declines the only pending INVITE for a provider call scoped to this SIP profile', async () => {
    const client = createJanusSipVoiceClient();
    client.sipHandle = {
      send: pluginSendMock,
      hangup: pluginHangupMock,
    };
    client.pendingIncomingCall = {
      callId: 'janus-call-a',
      result: { call_id: 'janus-call-a' },
    };
    client.currentCallRef = 'janus-call-a';

    const result = await client.rejectIncomingCall({
      callRef: 'logical-provider-call-a',
    });

    expect(pluginSendMock).toHaveBeenCalledWith({
      message: { request: 'decline' },
    });
    expect(pluginHangupMock).not.toHaveBeenCalled();
    expect(result).toEqual(expect.objectContaining({ declined: true }));
    expect(client.pendingIncomingCall).toBeNull();
  });

  it('accepts only the matching pending Janus incoming call when a call ref is provided', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });

    pluginState.options?.onmessage?.(
      {
        result: {
          event: 'incomingcall',
          call_id: 'janus-invite-1',
          username: 'sip:+77010000000@ats01.kz.sipuni.com',
        },
      },
      { type: 'offer', sdp: 'remote-offer-sdp' }
    );

    expect(
      JanusSipVoiceClient.hasPendingIncomingCall({
        callRef: 'other-invite',
        strict: true,
      })
    ).toBe(false);
    expect(
      JanusSipVoiceClient.hasPendingIncomingCall({
        callRef: 'janus-invite-1',
        strict: true,
      })
    ).toBe(true);

    const joinPromise = JanusSipVoiceClient.joinClientCall({
      callRef: 'sipuni:provider-session',
      callDirection: 'inbound',
      janusCallRef: 'janus-invite-1',
    });

    await new Promise(resolve => {
      window.setTimeout(resolve, 200);
    });

    pluginState.options?.onmessage?.({
      result: { event: 'accepted' },
    });

    const result = await joinPromise;

    expect(result).toEqual(
      expect.objectContaining({
        provider: 'sipuni',
        answered: true,
      })
    );
    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'accept',
          autoaccept_reinvites: false,
        }),
        jsep: { type: 'answer', sdp: 'mock-answer-sdp' },
      })
    );
  });

  it('waits for Janus accepted before resolving an inbound browser SIP call', async () => {
    await JanusSipVoiceClient.initializeDevice(asteriskAnalogSession, {
      inboxId: 4771,
    });

    pluginState.options?.onmessage?.(
      {
        result: {
          event: 'incomingcall',
          call_id: 'asterisk-invite-1',
          username: 'sip:+77010000000@10.77.0.2',
        },
      },
      { type: 'offer', sdp: 'remote-offer-sdp' }
    );

    let resolved = false;
    const joinPromise = JanusSipVoiceClient.joinClientCall({
      callRef: 'asterisk_analog:janus:41:asterisk-invite-1',
      callDirection: 'inbound',
      janusCallRef: 'asterisk-invite-1',
    }).then(result => {
      resolved = true;
      return result;
    });

    await new Promise(resolve => {
      window.setTimeout(resolve, 200);
    });

    expect(resolved).toBe(false);
    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({ request: 'accept' }),
      })
    );

    pluginState.options?.onmessage?.({
      result: { event: 'accepted' },
    });

    await expect(joinPromise).resolves.toEqual(
      expect.objectContaining({
        provider: 'asterisk_analog',
        answered: true,
        callRef: 'asterisk_analog:janus:41:asterisk-invite-1',
        callDirection: 'inbound',
      })
    );
  });

  it('declines an inbound SIP call when browser media negotiation fails', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    pluginHandleState.createAnswerImplementation = ({ error }) => {
      error(new Error('microphone_denied'));
    };
    pluginState.options?.onmessage?.(
      {
        call_id: 'janus-invite-media-failure',
        result: {
          event: 'incomingcall',
          username: 'sip:+77010000000@ats01.kz.sipuni.com',
        },
      },
      { type: 'offer', sdp: 'remote-offer-sdp' }
    );

    await expect(
      JanusSipVoiceClient.joinClientCall({
        callRef: 'sipuni:provider-media-failure',
        callDirection: 'inbound',
        janusCallRef: 'janus-invite-media-failure',
      })
    ).rejects.toThrow('microphone_denied');

    expect(pluginSendMock).toHaveBeenCalledWith({
      message: { request: 'decline', code: 480 },
    });
    expect(pluginHangupMock).toHaveBeenCalled();
    expect(JanusSipVoiceClient.pendingIncomingCall).toBeNull();
    expect(JanusSipVoiceClient.hasActiveCall).toBe(false);
  });

  it('hangs up when Janus never confirms an inbound accept', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    pluginState.options?.onmessage?.(
      {
        call_id: 'janus-invite-accept-timeout',
        result: {
          event: 'incomingcall',
          username: 'sip:+77010000000@ats01.kz.sipuni.com',
        },
      },
      { type: 'offer', sdp: 'remote-offer-sdp' }
    );
    const join = JanusSipVoiceClient.joinClientCall({
      callRef: 'sipuni:provider-accept-timeout',
      callDirection: 'inbound',
      janusCallRef: 'janus-invite-accept-timeout',
    });
    const rejection = expect(join).rejects.toThrow('incoming_accept_timeout');
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(10_000);

    await rejection;
    expect(pluginSendMock).toHaveBeenCalledWith({
      message: { request: 'hangup' },
    });
    expect(pluginHangupMock).toHaveBeenCalled();
    expect(JanusSipVoiceClient.hasActiveCall).toBe(false);
  });

  it('ignores a late BYE from an older inbound Janus call', () => {
    const client = createJanusSipVoiceClient();
    const disconnectedHandler = vi.fn();
    client.addEventListener('call:disconnected', disconnectedHandler);
    client.sessionConfig = sipuniSession;
    client.currentCallDirection = 'inbound';
    client.currentCallRef = 'sipuni:provider-current';
    client.currentJanusCallId = 'janus-current';
    client.hasActiveCall = true;
    client.sipHandle = { hangup: vi.fn() };

    client.handleSipMessage({
      call_id: 'janus-previous',
      result: { event: 'hangup', code: 200, reason: 'SIP BYE' },
    });

    expect(disconnectedHandler).not.toHaveBeenCalled();
    expect(client.hasActiveCall).toBe(true);
    expect(client.currentJanusCallId).toBe('janus-current');
  });

  it('keeps E.164 outbound dial URIs for regular SIP providers', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      toNumber: '+77066318623',
    });

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'call',
          uri: 'sip:+77066318623@ats01.kz.sipuni.com',
        }),
      })
    );
  });

  it('reports the native SIP ringing stage for the current outbound call', async () => {
    const stageHandler = vi.fn();
    JanusSipVoiceClient.addEventListener('call:stage', stageHandler);
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:ringing',
      toNumber: '+77066318623',
    });
    pluginState.options?.onmessage?.({
      call_id: 'outbound-call-id',
      result: { event: 'ringing' },
    });

    expect(stageHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          stage: 'ringing',
          janusCallId: 'outbound-call-id',
        }),
      })
    );
  });

  it('keeps the outbound setup timeout active after SIP early media', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();

    const join = JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:early-media-timeout',
      toNumber: '+77066318623',
    });
    await vi.advanceTimersByTimeAsync(1);
    await join;
    pluginState.options?.onmessage?.({
      call_id: 'outbound-call-id',
      result: { event: 'progress' },
    });
    await vi.advanceTimersByTimeAsync(45_000);

    expect(pluginSendMock).toHaveBeenCalledWith({
      message: { request: 'hangup' },
    });
    expect(JanusSipVoiceClient.hasActiveCall).toBe(false);
    expect(JanusSipVoiceClient.currentCallRef).toBeNull();
  });

  it('keeps the existing microphone track during a SIP re-INVITE', () => {
    const client = createJanusSipVoiceClient();
    const send = vi.fn();
    const createAnswer = vi.fn(({ success }) => {
      success({ type: 'answer', sdp: 'updated-answer' });
    });
    client.sipHandle = { createAnswer, send };

    client.answerUpdate({ type: 'offer', sdp: 'updated-offer' });

    expect(createAnswer).toHaveBeenCalledWith(
      expect.objectContaining({
        jsep: { type: 'offer', sdp: 'updated-offer' },
        tracks: [],
      })
    );
    expect(send).toHaveBeenCalledWith({
      message: { request: 'update' },
      jsep: { type: 'answer', sdp: 'updated-answer' },
    });
  });

  it('terminates a call when a SIP re-INVITE cannot be answered', () => {
    const client = createJanusSipVoiceClient();
    const send = vi.fn();
    const hangup = vi.fn();
    const disconnectedHandler = vi.fn();
    client.addEventListener('call:disconnected', disconnectedHandler);
    client.sessionConfig = sipuniSession;
    client.currentCallDirection = 'inbound';
    client.currentCallRef = 'sipuni:provider-reinvite';
    client.currentJanusCallId = 'janus-reinvite';
    client.hasActiveCall = true;
    client.sipHandle = {
      createAnswer: ({ error }) => error(new Error('invalid_reinvite_sdp')),
      send,
      hangup,
    };

    client.handleSipMessage(
      {
        call_id: 'janus-reinvite',
        result: { event: 'updatingcall' },
      },
      { type: 'offer', sdp: 'invalid-updated-offer' }
    );

    expect(send).toHaveBeenCalledWith({ message: { request: 'hangup' } });
    expect(hangup).toHaveBeenCalled();
    expect(disconnectedHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({ reason: 'sip_reinvite_failed' }),
      })
    );
  });

  it('transfers the live prewarmed microphone track into the Janus offer', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    const track = fakeAudioTrack('prewarmed-track');
    JanusSipVoiceClient.microphonePrewarmStream = {
      getAudioTracks: () => [track],
      getTracks: () => [track],
    };
    let createOfferOptions;
    pluginHandleState.createOfferImplementation = options => {
      createOfferOptions = options;
      options.success?.({ type: 'offer', sdp: 'mock-sdp' });
    };

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:prewarmed',
      toNumber: '+77066318623',
    });

    expect(createOfferOptions.tracks[0].capture).toBe(track);
    expect(track.stop).not.toHaveBeenCalled();
    expect(JanusSipVoiceClient.microphonePrewarmStream).toBeNull();
  });

  it('cancels an outbound join while refreshed registration is still pending', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    pluginSendMock.mockImplementation(() => {});

    const join = JanusSipVoiceClient.joinClientCall({
      provider: 'sipuni',
      inboxId: 4769,
      callRef: 'call-cancel-during-registration',
      callDirection: 'outbound',
      toNumber: '77015550006',
    });
    const rejection = expect(join).rejects.toMatchObject({
      reason: 'operator_cancelled',
      sipCallSent: false,
    });

    await JanusSipVoiceClient.endClientCall({
      provider: 'sipuni',
      inboxId: 4769,
    });
    await rejection;

    pluginState.options?.onmessage?.({ result: { event: 'registered' } });
    await vi.advanceTimersByTimeAsync(0);

    expect(
      pluginSendMock.mock.calls.filter(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toHaveLength(0);
    vi.useRealTimers();
  });

  it('does not create an offer after cancellation during microphone release', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    const createOffer = vi.fn();
    pluginHandleState.createOfferImplementation = createOffer;
    JanusSipVoiceClient.microphonePrewarmPromise = new Promise(() => {});

    const join = JanusSipVoiceClient.joinClientCall({
      provider: 'sipuni',
      inboxId: 4769,
      callRef: 'call-cancel-during-microphone-release',
      callDirection: 'outbound',
      toNumber: '77015550007',
    });
    const rejection = expect(join).rejects.toMatchObject({
      reason: 'operator_cancelled',
      sipCallSent: false,
    });
    await vi.advanceTimersByTimeAsync(0);

    await JanusSipVoiceClient.endClientCall({
      provider: 'sipuni',
      inboxId: 4769,
    });
    await rejection;
    await vi.advanceTimersByTimeAsync(1_000);

    expect(createOffer).not.toHaveBeenCalled();
    vi.useRealTimers();
  });

  it('delegates a cancelled pending-offer reset to outer fresh-ticket recovery', async () => {
    const unregisteredHandler = vi.fn();
    JanusSipVoiceClient.addEventListener(
      'call:unregistered',
      unregisteredHandler
    );
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    attachMock.mockClear();
    let lateOffer;
    pluginHandleState.createOfferImplementation = options => {
      lateOffer = options;
    };

    const firstJoin = JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:first',
      toNumber: '+77015558623',
    });
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });
    await JanusSipVoiceClient.endClientCall();

    await expect(firstJoin).rejects.toMatchObject({
      reason: 'operator_cancelled',
      sipCallSent: false,
    });
    lateOffer.success?.({ type: 'offer', sdp: 'late-offer' });
    expect(
      pluginSendMock.mock.calls.filter(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toHaveLength(0);

    expect(pluginDetachMock).toHaveBeenCalled();
    expect(janusDestroyMock).toHaveBeenCalled();
    expect(attachMock).not.toHaveBeenCalled();
    expect(unregisteredHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          reason: 'outbound_sip_handle_reset',
        }),
      })
    );

    pluginHandleState.createOfferImplementation = null;
    const secondJoin = await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:second',
      toNumber: '+77015558623',
    });

    expect(secondJoin).toBeNull();
    expect(
      pluginSendMock.mock.calls.filter(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toHaveLength(0);
  });

  it('times out before a SIP call when createOffer never settles', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    pluginHandleState.createOfferImplementation = () => {};

    const join = JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:offer-timeout',
      toNumber: '+77066318623',
    });
    const rejection = expect(join).rejects.toMatchObject({
      reason: 'sip_outbound_offer_timeout',
      sipCallSent: false,
    });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(20_000);

    await rejection;
    expect(
      pluginSendMock.mock.calls.some(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toBe(false);
    expect(
      pluginSendMock.mock.calls.some(
        ([payload]) => payload?.message?.request === 'hangup'
      )
    ).toBe(false);
    expect(pluginHangupMock).toHaveBeenCalledTimes(1);
  });

  it('classifies a missing Janus calling event after the SIP call was sent', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    pluginSendMock.mockImplementation(({ message } = {}) => {
      if (message?.request === 'register') {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({ result: { event: 'registered' } });
        }, 0);
      }
    });

    const join = JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'sipuni:local:calling-timeout',
      toNumber: '+77066318623',
    });
    const rejection = expect(join).rejects.toMatchObject({
      reason: 'sip_outbound_calling_timeout',
      sipCallSent: true,
    });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(20_000);

    await rejection;
    expect(
      pluginSendMock.mock.calls.filter(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toHaveLength(1);
    expect(
      pluginSendMock.mock.calls.filter(
        ([payload]) => payload?.message?.request === 'hangup'
      )
    ).toHaveLength(1);
  });

  it('does not start a Sipuni outbound call when Janus reports registration unavailable', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    JanusSipVoiceClient.handleSipMessage({
      result: { event: 'unregistered', code: 408, reason: 'registration lost' },
    });
    pluginSendMock.mockImplementation(({ message } = {}) => {
      if (message?.request === 'register') {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({
            error: 'SIP registration unavailable',
          });
        }, 0);
      }
    });
    pluginSendMock.mockClear();
    updatePresenceMock.mockClear();

    await expect(
      JanusSipVoiceClient.joinClientCall({
        callDirection: 'outbound',
        callRef: 'sipuni:local:stale-registration',
        toNumber: '+77066318623',
      })
    ).rejects.toThrow('SIP registration unavailable');

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
        }),
      })
    );
    expect(
      pluginSendMock.mock.calls.some(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toBe(false);
    expect(JanusSipVoiceClient.currentCallRef).toBeNull();
  });

  it('keeps the healthy Janus registration after a completed native browser call', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    pluginSendMock.mockClear();

    JanusSipVoiceClient.currentCallRef = 'sipuni:local:completed-call';
    JanusSipVoiceClient.currentCallDirection = 'inbound';
    JanusSipVoiceClient.hasActiveCall = true;
    JanusSipVoiceClient.handleCallDisconnected({
      reason: 'remote_hangup',
    });

    await vi.advanceTimersByTimeAsync(250);

    expect(JanusSipVoiceClient.registered).toBe(true);
    expect(pluginSendMock).not.toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
        }),
      })
    );
  });

  it('normalizes the documented Janus SIP BYE event as a remote hangup', () => {
    const client = createJanusSipVoiceClient();
    const disconnectedHandler = vi.fn();
    const callRef = 'sipuni:local:remote-bye';
    client.addEventListener('call:disconnected', disconnectedHandler);
    client.sessionConfig = sipuniSession;
    client.currentCallRef = callRef;
    client.currentCallDirection = 'outbound';
    client.hasActiveCall = true;
    client.callMediaAccepted = true;
    client.sipHandle = { hangup: vi.fn() };
    client.outboundAttempt = {
      callRef,
      janusCallId: 'janus-remote-bye',
      startSettled: true,
      timer: null,
      audioTrack: null,
    };

    client.handleSipMessage({
      call_id: 'janus-remote-bye',
      result: { event: 'hangup', code: 200, reason: 'SIP BYE' },
    });

    expect(disconnectedHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          callRef,
          reason: 'remote_hangup',
          janusReason: 'SIP BYE',
        }),
      })
    );
  });

  it('marks AI bridge browser calls so operator UI does not claim their media events', () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig = sipuniSession;
    client.sessionKey = 'sip_profile:42';
    client.sipProfileId = 42;
    client.inboxId = 4772;
    client.currentCallRef = 'sipuni:janus:42:ai-call';
    client.currentCallDirection = 'inbound';
    client.currentCallHandledByAi = true;

    expect(client.callEventDetail()).toEqual(
      expect.objectContaining({
        provider: 'sipuni',
        callRef: 'sipuni:janus:42:ai-call',
        callDirection: 'inbound',
        callMode: 'ai',
        aiBridge: true,
      })
    );
  });

  it('does not play caller media in the operator browser while AI bridge handles the call', () => {
    const client = createJanusSipVoiceClient();
    const audioElement = {
      srcObject: { id: 'previous-stream' },
      pause: vi.fn(),
      play: vi.fn(),
      removeAttribute: vi.fn(),
      load: vi.fn(),
    };
    client.remoteAudioElement = audioElement;
    client.remoteStream = { id: 'caller-stream' };
    client.currentCallHandledByAi = true;

    client.attachRemoteStream();

    expect(audioElement.pause).toHaveBeenCalled();
    expect(audioElement.srcObject).toBeNull();
    expect(audioElement.removeAttribute).toHaveBeenCalledWith('src');
    expect(audioElement.play).not.toHaveBeenCalled();
  });

  it('attaches an already available caller stream when accepting an AI bridge call', async () => {
    const client = createJanusSipVoiceClient();
    client.initialized = true;
    client.sipHandle = {
      createAnswer: vi.fn(({ success }) => {
        success?.({ type: 'answer', sdp: 'mock-answer-sdp' });
      }),
      send: vi.fn(),
    };
    client.remoteStream = { id: 'caller-stream' };

    const accepted = client.acceptIncomingCallWithAiBridge(
      { jsep: { type: 'offer', sdp: 'mock-offer-sdp' } },
      {
        callRef: 'sipuni:janus:42:ai-call',
        streamUrl: 'ws://127.0.0.1:8082/v1/voice/sessions/1/stream',
      }
    );
    await Promise.resolve();
    client.resolveIncomingAccept({ answered: true });
    await accepted;

    expect(janusAiMediaBridgeInstances).toHaveLength(1);
    expect(
      janusAiMediaBridgeInstances[0].attachRemoteStream
    ).toHaveBeenCalledWith(client.remoteStream);
    expect(client.sipHandle.createAnswer).toHaveBeenCalledWith(
      expect.objectContaining({
        tracks: [
          expect.objectContaining({
            capture: expect.objectContaining({ id: 'ai-output-track' }),
            recv: true,
            type: 'audio',
          }),
        ],
      })
    );
  });

  it('delegates an unexpected Janus destroy to outer fresh-ticket recovery', async () => {
    const client = createJanusSipVoiceClient();
    const unregisteredHandler = vi.fn();
    client.addEventListener('call:unregistered', unregisteredHandler);
    await client.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    attachMock.mockClear();
    updatePresenceMock.mockClear();

    client.handleJanusDestroyed();

    expect(updatePresenceMock).toHaveBeenCalledWith(
      false,
      expect.objectContaining({ inboxId: 4769 })
    );
    expect(unregisteredHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({ reason: 'janus_destroyed' }),
      })
    );

    await vi.advanceTimersByTimeAsync(1_000);

    expect(attachMock).not.toHaveBeenCalled();
  });

  it('uses an explicit Janus keepalive interval below the gateway timeout', async () => {
    const client = createJanusSipVoiceClient();

    await client.initializeDevice(sipuniSession, { inboxId: 4769 });

    expect(janusState.instances.at(-1)?.options.keepAlivePeriod).toBe(15_000);
  });

  it('does not recover the Janus SIP device during intentional destroy', async () => {
    const client = createJanusSipVoiceClient();
    await client.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    vi.useFakeTimers();
    attachMock.mockClear();

    await client.destroyDevice();
    await vi.advanceTimersByTimeAsync(1_000);

    expect(attachMock).not.toHaveBeenCalled();
  });

  it('sends Asterisk analog outbound calls in the PBX dialplan format', async () => {
    await JanusSipVoiceClient.initializeDevice(asteriskAnalogSession, {
      inboxId: 4771,
    });

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      toNumber: '+77066318623',
    });

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'call',
          uri: 'sip:77066318623@10.77.0.2',
        }),
      })
    );
  });

  it('notifies the UI when an outbound Asterisk analog call is accepted', async () => {
    const connectedHandler = vi.fn();
    JanusSipVoiceClient.addEventListener('call:connected', connectedHandler);
    await JanusSipVoiceClient.initializeDevice(asteriskAnalogSession, {
      inboxId: 4771,
    });

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      callRef: 'asterisk_analog:local:accepted-outbound',
      toNumber: '+77066318623',
    });
    pluginState.options?.onmessage?.({
      result: { event: 'accepted' },
    });

    expect(connectedHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          provider: 'asterisk_analog',
          callRef: 'asterisk_analog:local:accepted-outbound',
          callDirection: 'outbound',
          callMediaAccepted: true,
        }),
      })
    );
    JanusSipVoiceClient.removeEventListener('call:connected', connectedHandler);
  });

  it('starts an Asterisk analog outbound call on the existing Janus registration', async () => {
    await JanusSipVoiceClient.initializeDevice(asteriskAnalogSession, {
      inboxId: 4771,
    });
    pluginSendMock.mockClear();

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      toNumber: '+77066318623',
    });

    const requests = pluginSendMock.mock.calls
      .map(([payload]) => payload?.message?.request)
      .filter(Boolean);
    expect(requests).toEqual(['call']);
  });

  it('supports Kazakhstan trunk dialing for Asterisk analog profiles', async () => {
    await JanusSipVoiceClient.initializeDevice(
      {
        ...asteriskAnalogSession,
        sip: {
          ...asteriskAnalogSession.sip,
          outboundDialFormat: 'kz_trunk',
        },
      },
      {
        inboxId: 4771,
      }
    );

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      toNumber: '+77066318623',
    });

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'call',
          uri: 'sip:87066318623@10.77.0.2',
        }),
      })
    );
  });

  it('supports E.164 dialing for Asterisk analog profiles', async () => {
    await JanusSipVoiceClient.initializeDevice(
      {
        ...asteriskAnalogSession,
        sip: {
          ...asteriskAnalogSession.sip,
          outboundDialFormat: 'e164',
        },
      },
      {
        inboxId: 4771,
      }
    );

    await JanusSipVoiceClient.joinClientCall({
      callDirection: 'outbound',
      toNumber: '87066318623',
    });

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'call',
          uri: 'sip:+77066318623@10.77.0.2',
        }),
      })
    );
  });

  it('records and uploads answered Asterisk analog browser SIP media', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskAnalogSession;
      client.currentCallRef = 'asterisk_analog:local:call-1';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(MediaRecorderMock.instances[0].audioBitsPerSecond).toBe(128_000);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'asterisk_analog:local:call-1',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'asterisk_analog',
          direction: 'outbound',
          reason: 'remote_hangup',
          terminal_status: 'completed',
        })
      );
    } finally {
      restore();
    }
  });

  it('does not start browser recording before call media is accepted', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskAnalogSession;
      client.currentCallRef = 'asterisk_analog:local:call-ringing';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = false;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();

      expect(MediaRecorderMock.instances).toHaveLength(0);
      expect(uploadRecordingMock).not.toHaveBeenCalled();
    } finally {
      restore();
    }
  });

  it('releases an outbound call directly when recording upload fails', async () => {
    const { restore } = installRecordingMocks();
    try {
      uploadRecordingMock.mockRejectedValueOnce(new Error('upload failed'));
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskAnalogSession;
      client.currentCallRef = 'asterisk_analog:local:call-upload-failed';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      await vi.waitFor(() => {
        expect(rejectIncomingCallMock).toHaveBeenCalledWith(
          'asterisk_analog:local:call-upload-failed',
          {
            status: 'completed',
            reason: 'remote_hangup',
          }
        );
      });
    } finally {
      restore();
    }
  });

  it('waits for recording persistence and guards reload while upload is pending', async () => {
    const { restore } = installRecordingMocks();
    let resolveUpload;
    uploadRecordingMock.mockReturnValueOnce(
      new Promise(resolve => {
        resolveUpload = resolve;
      })
    );

    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = sipuniSession;
      client.sipHandle = { send: vi.fn(), hangup: vi.fn() };
      client.currentCallRef = 'sipuni:local:persist-before-reload';
      client.currentCallDirection = 'outbound';
      client.hasActiveCall = true;
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };
      client.startRecordingIfReady();

      const ending = client.endClientCall();
      await vi.waitFor(() => {
        expect(uploadRecordingMock).toHaveBeenCalledTimes(1);
      });

      const pendingUnload = new Event('beforeunload', { cancelable: true });
      window.dispatchEvent(pendingUnload);
      expect(pendingUnload.defaultPrevented).toBe(true);

      let endingSettled = false;
      ending.then(() => {
        endingSettled = true;
      });
      await Promise.resolve();
      expect(endingSettled).toBe(false);

      resolveUpload({});
      await ending;

      const completedUnload = new Event('beforeunload', { cancelable: true });
      window.dispatchEvent(completedUnload);
      expect(completedUnload.defaultPrevented).toBe(false);
    } finally {
      restore();
    }
  });

  it('records both browser SIP sides without fixed gain that can clip speech', () => {
    const {
      createdDestinations,
      createdGains,
      createdSources,
      MediaRecorderMock,
      restore,
    } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskAnalogSession;
      client.currentCallRef = 'asterisk_analog:local:call-gain';
      client.currentCallDirection = 'inbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(createdSources).toHaveLength(2);
      expect(createdGains).toHaveLength(0);
      expect(createdSources[0].connect).toHaveBeenCalledWith(
        createdDestinations[0]
      );
      expect(createdSources[1].connect).toHaveBeenCalledWith(
        createdDestinations[0]
      );
    } finally {
      restore();
    }
  });

  it('keeps the browser recording when Janus fires duplicate cleanup before recorder stop', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks({
      stopImmediately: false,
    });
    try {
      const client = createJanusSipVoiceClient();
      const disconnectedHandler = vi.fn();
      client.addEventListener('call:disconnected', disconnectedHandler);
      client.sessionConfig = asteriskAnalogSession;
      client.currentCallRef = 'asterisk_analog:local:call-dup-cleanup';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.stopAndUploadRecording({ reason: 'remote_hangup' });
      client.handlePeerCleanup();

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(uploadRecordingMock).not.toHaveBeenCalled();
      expect(disconnectedHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          detail: expect.objectContaining({
            provider: 'asterisk_analog',
            callRef: 'asterisk_analog:local:call-dup-cleanup',
            callDirection: 'outbound',
            callMediaAccepted: true,
            reason: 'remote_hangup',
          }),
        })
      );

      MediaRecorderMock.instances[0].flushStop();

      expect(uploadRecordingMock).toHaveBeenCalledTimes(1);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'asterisk_analog:local:call-dup-cleanup',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'asterisk_analog',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });

  it('reports an active outbound call as disconnected when the SIP device is destroyed', async () => {
    const client = createJanusSipVoiceClient();
    const disconnectedHandler = vi.fn();
    const sipSendMock = vi.fn();
    const sipDetachMock = vi.fn();
    client.addEventListener('call:disconnected', disconnectedHandler);
    client.sessionConfig = asteriskAnalogSession;
    client.sessionKey = 'sip_profile:41';
    client.sipProfileId = 41;
    client.inboxId = 4771;
    client.initialized = true;
    client.registered = true;
    client.sipHandle = {
      send: sipSendMock,
      detach: sipDetachMock,
    };
    client.currentCallRef = 'asterisk_analog:local:destroyed-outbound';
    client.currentCallDirection = 'outbound';
    client.hasActiveCall = true;

    await client.destroyDevice();

    expect(disconnectedHandler).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          provider: 'asterisk_analog',
          sessionKey: 'sip_profile:41',
          sipProfileId: 41,
          inboxId: 4771,
          callRef: 'asterisk_analog:local:destroyed-outbound',
          callDirection: 'outbound',
          reason: 'device_destroyed',
        }),
      })
    );
    expect(sipSendMock).toHaveBeenCalledWith({
      message: { request: 'unregister' },
    });
    expect(sipDetachMock).toHaveBeenCalled();
  });

  it('starts Janus server recording and a concurrent browser safety copy', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskServerRecordingSession;
      client.sipProfileId = 77;
      client.sipHandle = { send: pluginSendMock };
      client.currentCallRef = 'asterisk_analog:local:server-recording-1';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };
      pluginSendMock.mockClear();

      client.startRecordingIfReady();

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(client.janusServerRecordingStarting).toBe(true);
      expect(client.janusServerRecordingStarted).toBe(false);
      expect(pluginSendMock).toHaveBeenCalledWith(
        expect.objectContaining({
          message: expect.objectContaining({
            request: 'recording',
            action: 'start',
          }),
        })
      );

      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(pluginSendMock).toHaveBeenCalledWith(
        expect.objectContaining({
          message: {
            request: 'recording',
            action: 'stop',
            audio: true,
            peer_audio: true,
          },
        })
      );
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'asterisk_analog:local:server-recording-1',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'asterisk_analog',
          direction: 'outbound',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });

  it('keeps browser recording when Janus server recording would have reported an async error', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      let recordingStartError;
      client.sessionConfig = asteriskServerRecordingSession;
      client.sipHandle = {
        send: vi.fn(({ message, error } = {}) => {
          if (message?.request === 'recording' && message?.action === 'start') {
            recordingStartError = error;
          }
        }),
      };
      client.currentCallRef =
        'asterisk_analog:local:server-recording-async-error';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(client.janusServerRecordingStarting).toBe(true);

      recordingStartError?.(new Error('Janus recorder unavailable'));
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'asterisk_analog:local:server-recording-async-error',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'asterisk_analog',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });

  it('falls back to browser recording when Janus server recording cannot start', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskServerRecordingSession;
      client.currentCallRef = 'asterisk_analog:local:server-recording-fallback';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'asterisk_analog:local:server-recording-fallback',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'asterisk_analog',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });

  it('server-records inbound Asterisk calls with a browser safety copy', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = asteriskServerRecordingSession;
      client.sipHandle = { send: pluginSendMock };
      client.currentCallRef = 'asterisk_analog:janus:61:inbound-call';
      client.currentCallDirection = 'inbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };
      pluginSendMock.mockClear();

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(pluginSendMock).toHaveBeenCalledWith(
        expect.objectContaining({
          message: expect.objectContaining({
            request: 'recording',
            action: 'start',
          }),
        })
      );
      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'asterisk_analog:janus:61:inbound-call',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'asterisk_analog',
          direction: 'inbound',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });

  it('records and uploads answered Binotel browser SIP media', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = binotelSession;
      client.currentCallRef = 'binotel:local:call-1';
      client.currentCallDirection = 'inbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'binotel:local:call-1',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'binotel',
          direction: 'inbound',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });

  it('browser-records Sipuni calls when provider API recording needs fallback', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipVoiceClient();
      client.sessionConfig = sipuniSession;
      client.currentCallRef = 'sipuni:local:call-1';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(MediaRecorderMock.instances).toHaveLength(1);
      expect(uploadRecordingMock).toHaveBeenCalledWith(
        'sipuni:local:call-1',
        expect.any(Blob),
        expect.objectContaining({
          provider: 'sipuni',
          direction: 'outbound',
          reason: 'remote_hangup',
        })
      );
    } finally {
      restore();
    }
  });
});
