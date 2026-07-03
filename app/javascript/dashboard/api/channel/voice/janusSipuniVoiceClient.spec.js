import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  attachMock,
  janusDestroyMock,
  pluginDetachMock,
  pluginSendMock,
  pluginState,
  uploadRecordingMock,
  updatePresenceMock,
} = vi.hoisted(() => ({
  attachMock: vi.fn(),
  janusDestroyMock: vi.fn(),
  pluginDetachMock: vi.fn(),
  pluginSendMock: vi.fn(),
  pluginState: { options: null },
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

import JanusSipuniVoiceClient, {
  createJanusSipuniVoiceClient,
} from './janusSipuniVoiceClient';

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
      return { stream: new MediaStreamMock() };
    };

  AudioContextMock.prototype.createMediaStreamSource =
    function createMediaStreamSource() {
      return { connect: vi.fn() };
    };

  AudioContextMock.prototype.close = function close() {
    return Promise.resolve();
  };

  function MediaRecorderMock(stream, options = {}) {
    this.stream = stream;
    this.mimeType = options.mimeType || 'audio/webm';
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
    MediaRecorderMock,
    restore: () => {
      window.AudioContext = original.AudioContext;
      window.MediaRecorder = original.MediaRecorder;
      window.MediaStream = original.MediaStream;
    },
  };
};

describe('janusSipuniVoiceClient', () => {
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
    await JanusSipuniVoiceClient.destroyDevice();
    attachMock.mockClear();
    janusDestroyMock.mockClear();
    pluginDetachMock.mockClear();
    pluginSendMock.mockClear();
    uploadRecordingMock.mockClear();
    updatePresenceMock.mockClear();
  });

  afterEach(async () => {
    await JanusSipuniVoiceClient.destroyDevice();
    audioPlaySpy?.mockRestore();
  });

  it('reports the previous inbox offline before registering the next inbox', async () => {
    await JanusSipuniVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });

    expect(updatePresenceMock).toHaveBeenLastCalledWith(true, {
      inboxId: 4769,
    });
    updatePresenceMock.mockClear();

    await JanusSipuniVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4770,
    });

    expect(updatePresenceMock.mock.calls).toEqual([
      [false, { inboxId: 4769 }],
      [true, { inboxId: 4770 }],
    ]);
    expect(janusDestroyMock).toHaveBeenCalledTimes(1);
    expect(pluginDetachMock).toHaveBeenCalledTimes(1);
  });

  it('keeps Binotel as the active provider for Janus SIP sessions', async () => {
    const state = await JanusSipuniVoiceClient.initializeDevice(
      binotelSession,
      {
        inboxId: 4769,
      }
    );

    expect(state).toEqual(
      expect.objectContaining({
        provider: 'binotel',
        callingSupported: true,
        registered: true,
        internalExtension: '901',
      })
    );
    expect(updatePresenceMock).toHaveBeenLastCalledWith(true, {
      inboxId: 4769,
    });
  });

  it('accepts only the matching pending Janus incoming call when a call ref is provided', async () => {
    await JanusSipuniVoiceClient.initializeDevice(sipuniSession, {
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
      JanusSipuniVoiceClient.hasPendingIncomingCall({
        callRef: 'other-invite',
        strict: true,
      })
    ).toBe(false);
    expect(
      JanusSipuniVoiceClient.hasPendingIncomingCall({
        callRef: 'janus-invite-1',
        strict: true,
      })
    ).toBe(true);

    const result = await JanusSipuniVoiceClient.joinClientCall({
      callRef: 'sipuni:provider-session',
      callDirection: 'inbound',
      janusCallRef: 'janus-invite-1',
    });

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

  it('keeps E.164 outbound dial URIs for regular SIP providers', async () => {
    await JanusSipuniVoiceClient.initializeDevice(sipuniSession, {
      inboxId: 4769,
    });

    await JanusSipuniVoiceClient.joinClientCall({
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

  it('sends Asterisk analog outbound calls in the PBX dialplan format', async () => {
    await JanusSipuniVoiceClient.initializeDevice(asteriskAnalogSession, {
      inboxId: 4771,
    });

    await JanusSipuniVoiceClient.joinClientCall({
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

  it('refreshes SIP registration before Asterisk analog outbound calls', async () => {
    await JanusSipuniVoiceClient.initializeDevice(asteriskAnalogSession, {
      inboxId: 4771,
    });
    pluginSendMock.mockClear();

    await JanusSipuniVoiceClient.joinClientCall({
      callDirection: 'outbound',
      toNumber: '+77066318623',
    });

    const requests = pluginSendMock.mock.calls
      .map(([payload]) => payload?.message?.request)
      .filter(Boolean);
    expect(requests).toEqual(expect.arrayContaining(['register', 'call']));
    expect(requests.indexOf('register')).toBeLessThan(requests.indexOf('call'));
  });

  it('supports Kazakhstan trunk dialing for Asterisk analog profiles', async () => {
    await JanusSipuniVoiceClient.initializeDevice(
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

    await JanusSipuniVoiceClient.joinClientCall({
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
    await JanusSipuniVoiceClient.initializeDevice(
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

    await JanusSipuniVoiceClient.joinClientCall({
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
      const client = createJanusSipuniVoiceClient();
      client.sessionConfig = asteriskAnalogSession;
      client.currentCallRef = 'asterisk_analog:local:call-1';
      client.currentCallDirection = 'outbound';
      client.callMediaAccepted = true;
      client.localTracks = { local: fakeAudioTrack('local') };
      client.remoteTracks = { remote: fakeAudioTrack('remote') };

      client.startRecordingIfReady();
      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(MediaRecorderMock.instances).toHaveLength(1);
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

  it('keeps the browser recording when Janus fires duplicate cleanup before recorder stop', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks({
      stopImmediately: false,
    });
    try {
      const client = createJanusSipuniVoiceClient();
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

  it('uses Janus server recording before browser fallback when configured', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipuniVoiceClient();
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

      expect(MediaRecorderMock.instances).toHaveLength(0);
      expect(client.janusServerRecordingStarting).toBe(true);
      expect(client.janusServerRecordingStarted).toBe(false);
      expect(uploadRecordingMock).not.toHaveBeenCalled();
      expect(pluginSendMock).toHaveBeenCalledWith(
        expect.objectContaining({
          message: expect.objectContaining({
            request: 'recording',
            action: 'start',
            audio: true,
            peer_audio: true,
            filename: expect.stringContaining(
              'janus-prod_asterisk_account_530_profile_77_env_ZGVmYXVsdA_asterisk_analog_account_530_profile_77_call_'
            ),
          }),
        })
      );

      client.handleSipMessage({ result: { event: 'recordingupdated' } });

      expect(client.janusServerRecordingStarting).toBe(false);
      expect(client.janusServerRecordingStarted).toBe(true);

      client.handleCallDisconnected({ reason: 'remote_hangup' });

      expect(pluginSendMock).toHaveBeenCalledWith({
        message: {
          request: 'recording',
          action: 'stop',
        },
      });
      expect(uploadRecordingMock).not.toHaveBeenCalled();
    } finally {
      restore();
    }
  });

  it('falls back to browser recording when Janus server recording reports an async error', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipuniVoiceClient();
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

      expect(MediaRecorderMock.instances).toHaveLength(0);
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
      const client = createJanusSipuniVoiceClient();
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

  it('records and uploads answered Binotel browser SIP media', () => {
    const { MediaRecorderMock, restore } = installRecordingMocks();
    try {
      const client = createJanusSipuniVoiceClient();
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
      const client = createJanusSipuniVoiceClient();
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
