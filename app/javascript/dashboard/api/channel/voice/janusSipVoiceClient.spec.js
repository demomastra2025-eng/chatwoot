/* eslint-disable max-classes-per-file, class-methods-use-this */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  attachMock,
  janusDestroyMock,
  pluginDetachMock,
  pluginSendMock,
  pluginState,
  janusAiMediaBridgeInstances,
  uploadRecordingMock,
  updatePresenceMock,
} = vi.hoisted(() => ({
  attachMock: vi.fn(),
  janusDestroyMock: vi.fn(),
  pluginDetachMock: vi.fn(),
  pluginSendMock: vi.fn(),
  pluginState: { options: null },
  janusAiMediaBridgeInstances: [],
  uploadRecordingMock: vi.fn(() => Promise.resolve({})),
  updatePresenceMock: vi.fn(() => Promise.resolve()),
}));

vi.mock('webrtc-adapter', () => ({
  default: { browserDetails: { browser: 'chrome' } },
  browserDetails: { browser: 'chrome' },
}));

vi.mock('janus-gateway', () => {
  class JanusMock {
    constructor(options = {}) {
      this.options = options;
      window.setTimeout(() => options.success?.(), 0);
    }

    attach(options = {}) {
      this.pluginOptions = options;
      pluginState.options = options;
      attachMock(options);
      options.success?.({
        send: pluginSendMock,
        detach: pluginDetachMock,
        hangup: vi.fn(),
        createOffer: ({ success } = {}) => {
          success?.({ type: 'offer', sdp: 'mock-sdp' });
        },
        createAnswer: ({ success } = {}) => {
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
    uploadWebphoneRecording: uploadRecordingMock,
    updateWebphonePresence: updatePresenceMock,
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
    });
    await JanusSipVoiceClient.destroyDevice();
    attachMock.mockClear();
    janusDestroyMock.mockClear();
    pluginDetachMock.mockClear();
    pluginSendMock.mockClear();
    janusAiMediaBridgeInstances.length = 0;
    uploadRecordingMock.mockClear();
    updatePresenceMock.mockClear();
  });

  afterEach(async () => {
    await JanusSipVoiceClient.destroyDevice();
    audioPlaySpy?.mockRestore();
    vi.useRealTimers();
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

  it('sends offline presence only after an in-flight online report settles', async () => {
    const client = createJanusSipVoiceClient();
    let resolveOnlinePresence;
    updatePresenceMock.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveOnlinePresence = resolve;
        })
    );

    await client.initializeDevice(sipuniSession, { inboxId: 4769 });
    await client.destroyDevice();

    expect(updatePresenceMock).toHaveBeenCalledTimes(1);
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );

    resolveOnlinePresence?.({ registered_for_routing: true });
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

    await client.initializeDevice(
      { ...sipuniSession, registrationConfigVersion: 'version-1' },
      {
        inboxId: 4769,
      }
    );

    pluginSendMock.mockClear();
    resolvePresence?.({
      reason: 'sip_profile_registration_context_mismatch',
      registered_for_routing: false,
    });
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });

    expect(client.registered).toBe(false);
    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({ request: 'unregister' }),
      })
    );
    expect(pluginDetachMock).toHaveBeenCalledTimes(1);
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
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

    await client.initializeDevice(
      { ...sipuniSession, registrationConfigVersion: 'version-1' },
      {
        inboxId: 4769,
      }
    );

    pluginSendMock.mockClear();
    resolvePresence?.({
      reason: 'agent_binding_missing',
      calling_supported: false,
      registered_for_routing: false,
    });
    await new Promise(resolve => {
      window.setTimeout(resolve, 0);
    });

    expect(client.registered).toBe(false);
    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({ request: 'unregister' }),
      })
    );
    expect(pluginDetachMock).toHaveBeenCalledTimes(1);
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
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

  it('refreshes the Janus SIP registration during the presence heartbeat', async () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.sipHandle = { send: pluginSendMock };
    client.registered = true;
    client.inboxId = 4769;
    pluginSendMock.mockClear();
    updatePresenceMock.mockClear();

    const refresh = client.refreshPresenceRegistration();
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
    expect(updatePresenceMock).toHaveBeenCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );
  });

  it('falls back to a full Janus SIP registration when refresh finds a stale state', async () => {
    const client = createJanusSipVoiceClient();
    client.sessionConfig =
      JanusSipVoiceClientClass.normalizeSessionConfig(sipuniSession);
    client.sipHandle = { send: pluginSendMock };
    client.initialized = true;
    client.registered = true;
    client.inboxId = 4769;
    pluginSendMock
      .mockImplementationOnce(() => {
        window.setTimeout(() => {
          client.handleSipMessage({ error: 'Wrong state (not registered)' });
        }, 0);
      })
      .mockImplementationOnce(() => {
        window.setTimeout(() => {
          client.handleSipMessage({ result: { event: 'registered' } });
        }, 0);
      });
    updatePresenceMock.mockClear();

    await client.refreshPresenceRegistration();

    expect(pluginSendMock).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
        }),
      })
    );
    expect(pluginSendMock).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        message: expect.not.objectContaining({
          refresh: true,
        }),
      })
    );
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );
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
      await vi.advanceTimersByTimeAsync(8000);

      const error = await result;
      expect(error).toBeInstanceOf(Error);
      expect(error.message).toBe('sip_registration_timeout');
      expect(updatePresenceMock).toHaveBeenLastCalledWith(
        false,
        expect.objectContaining({ inboxId: 4769 })
      );

      updatePresenceMock.mockClear();
      pluginState.options?.onmessage?.({ result: { event: 'registered' } });

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

  it('does not start a Sipuni outbound call when Janus registration is stale', async () => {
    await JanusSipVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });
    pluginSendMock.mockImplementation(({ message } = {}) => {
      if (message?.request === 'register' && message?.refresh) {
        window.setTimeout(() => {
          pluginState.options?.onmessage?.({
            error: 'Wrong state (not registered)',
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
    ).rejects.toThrow('Wrong state (not registered)');

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
        }),
      })
    );
    expect(
      pluginSendMock.mock.calls.some(
        ([payload]) => payload?.message?.request === 'call'
      )
    ).toBe(false);
    expect(JanusSipVoiceClient.currentCallRef).toBeNull();
    expect(updatePresenceMock).toHaveBeenLastCalledWith(
      false,
      expect.objectContaining({ inboxId: 4769 })
    );
  });

  it('refreshes SIP registration after a completed native browser call', async () => {
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

    expect(pluginSendMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.objectContaining({
          request: 'register',
          refresh: true,
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

  it('recovers the Janus SIP device when the Janus session is unexpectedly destroyed', async () => {
    const client = createJanusSipVoiceClient();
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

    await vi.advanceTimersByTimeAsync(1_000);
    await vi.runOnlyPendingTimersAsync();
    await vi.runOnlyPendingTimersAsync();
    await client.deviceRecoveryPromise;

    expect(attachMock).toHaveBeenCalled();
    expect(updatePresenceMock).toHaveBeenCalledWith(
      true,
      expect.objectContaining({ inboxId: 4769 })
    );
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

  it('refreshes already registered Asterisk analog outbound calls with Janus refresh', async () => {
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
    expect(requests).toEqual(['register', 'call']);
    expect(pluginSendMock.mock.calls[0][0]?.message).toEqual(
      expect.objectContaining({
        request: 'register',
        refresh: true,
      })
    );
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
        })
      );
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
