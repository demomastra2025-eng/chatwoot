import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  attachMock,
  janusDestroyMock,
  pluginDetachMock,
  pluginSendMock,
  pluginState,
  updatePresenceMock,
} = vi.hoisted(() => ({
  attachMock: vi.fn(),
  janusDestroyMock: vi.fn(),
  pluginDetachMock: vi.fn(),
  pluginSendMock: vi.fn(),
  pluginState: { options: null },
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
    updateWebphonePresence: updatePresenceMock,
  },
}));

import JanusSipuniVoiceClient from './janusSipuniVoiceClient';

let audioPlaySpy;

const sipuniSession = {
  provider: 'sipuni',
  callingSupported: true,
  janusServer: 'wss://dev.one-link.kz/janus-sipuni',
  sip: {
    username: '990001000018',
    password: 'test-sip-password',
    host: 'ats01.kz.sipuni.com',
    internalExtension: '502',
  },
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
});
