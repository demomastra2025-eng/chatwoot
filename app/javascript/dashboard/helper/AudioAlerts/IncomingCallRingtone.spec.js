import { beforeEach, describe, expect, it, vi } from 'vitest';

import { IncomingCallRingtone } from './IncomingCallRingtone';

const flushPromises = () =>
  new Promise(resolve => {
    setTimeout(resolve, 0);
  });

const buildAudio = () => ({
  currentTime: 4,
  loop: false,
  preload: '',
  src: '',
  volume: 1,
  pause: vi.fn(),
  play: vi.fn().mockResolvedValue(undefined),
});

const buildEventTarget = () => {
  const listeners = new Map();
  return {
    addEventListener: vi.fn((eventName, handler) => {
      listeners.set(eventName, handler);
    }),
    removeEventListener: vi.fn((eventName, handler) => {
      if (listeners.get(eventName) === handler) listeners.delete(eventName);
    }),
    dispatch(eventName) {
      listeners.get(eventName)?.();
    },
    listeners,
  };
};

describe('IncomingCallRingtone', () => {
  let audio;
  let audioFactory;
  let eventTarget;
  let captureException;
  let permissionBlocked;
  let ringtone;

  beforeEach(() => {
    audio = buildAudio();
    audioFactory = vi.fn(() => audio);
    eventTarget = buildEventTarget();
    captureException = vi.fn();
    permissionBlocked = vi.fn();
    ringtone = new IncomingCallRingtone({
      audioFactory,
      eventTarget,
      captureException,
      onPermissionBlocked: permissionBlocked,
    });
  });

  it('plays the selected ringtone once for multiple active call sources', async () => {
    ringtone.setSourceState('voice', {
      active: true,
      tone: 'universfield-ringtone-028-380250',
    });
    ringtone.setSourceState('whatsapp', {
      active: true,
      tone: 'universfield-ringtone-028-380250',
    });
    await flushPromises();

    expect(audioFactory).toHaveBeenCalledTimes(1);
    expect(audio.src).toBe(
      '/audio/ringtone/universfield-ringtone-028-380250.mp3'
    );
    expect(audio.loop).toBe(true);
    expect(audio.preload).toBe('auto');
    expect(audio.play).toHaveBeenCalledTimes(1);
  });

  it('stops only after every call source becomes inactive', async () => {
    ringtone.setSourceState('voice', { active: true });
    ringtone.setSourceState('whatsapp', { active: true });
    await flushPromises();

    ringtone.setSourceState('voice', { active: false });
    expect(audio.pause).not.toHaveBeenCalled();

    ringtone.setSourceState('whatsapp', { active: false });
    expect(audio.pause).toHaveBeenCalledTimes(1);
    expect(audio.currentTime).toBe(0);
  });

  it('switches the audio source when the profile ringtone changes', async () => {
    const nextAudio = buildAudio();
    audioFactory.mockReturnValueOnce(audio).mockReturnValueOnce(nextAudio);

    ringtone.setSourceState('voice', {
      active: true,
      tone: 'universfield-ringtone-028-380250',
    });
    await flushPromises();
    ringtone.setSourceState('voice', {
      active: true,
      tone: 'universfield-ringtone-091-496417',
    });
    await flushPromises();

    expect(audio.pause).toHaveBeenCalledTimes(1);
    expect(nextAudio.src).toBe(
      '/audio/ringtone/universfield-ringtone-091-496417.mp3'
    );
    expect(nextAudio.play).toHaveBeenCalledTimes(1);
  });

  it('retries after a browser gesture when autoplay is blocked', async () => {
    const notAllowedError = Object.assign(new Error('blocked'), {
      name: 'NotAllowedError',
    });
    audio.play
      .mockRejectedValueOnce(notAllowedError)
      .mockResolvedValueOnce(undefined);

    ringtone.setSourceState('voice', { active: true });
    await flushPromises();

    expect(eventTarget.addEventListener).toHaveBeenCalledWith(
      'pointerdown',
      expect.any(Function),
      { once: true }
    );
    expect(eventTarget.addEventListener).toHaveBeenCalledWith(
      'keydown',
      expect.any(Function),
      { once: true }
    );
    expect(captureException).not.toHaveBeenCalled();
    expect(permissionBlocked).toHaveBeenCalledTimes(1);

    eventTarget.dispatch('pointerdown');
    await flushPromises();

    expect(audio.play).toHaveBeenCalledTimes(2);
  });

  describe('when the browser blocks the sound', () => {
    const notAllowedError = () =>
      Object.assign(new Error('blocked'), { name: 'NotAllowedError' });

    it('warns once for a ringing call however often playback is retried', async () => {
      audio.play.mockRejectedValue(notAllowedError());

      ringtone.setSourceState('voice', { active: true });
      await flushPromises();
      ringtone.setSourceState('whatsapp', { active: true });
      await flushPromises();
      ringtone.setSourceState('voice', { active: true });
      await flushPromises();

      expect(permissionBlocked).toHaveBeenCalledTimes(1);
    });

    it('warns again for every next call while the sound stays blocked', async () => {
      audio.play.mockRejectedValue(notAllowedError());

      ringtone.setSourceState('voice', { active: true });
      await flushPromises();
      ringtone.setSourceState('voice', { active: false });
      ringtone.setSourceState('voice', { active: true });
      await flushPromises();
      ringtone.removeSource('voice');
      ringtone.setSourceState('whatsapp', { active: true });
      await flushPromises();

      expect(permissionBlocked).toHaveBeenCalledTimes(3);
    });

    it('stays quiet for the next call once a gesture unblocked the sound', async () => {
      audio.play
        .mockRejectedValueOnce(notAllowedError())
        .mockResolvedValue(undefined);

      ringtone.setSourceState('voice', { active: true });
      await flushPromises();
      eventTarget.dispatch('pointerdown');
      await flushPromises();
      ringtone.setSourceState('voice', { active: false });
      ringtone.setSourceState('voice', { active: true });
      await flushPromises();

      expect(audio.play).toHaveBeenCalledTimes(3);
      expect(permissionBlocked).toHaveBeenCalledTimes(1);
    });

    it('does not warn for a call that rings silently by the profile setting', async () => {
      audio.play.mockRejectedValue(notAllowedError());

      ringtone.setSourceState('voice', { active: false });
      await flushPromises();

      expect(permissionBlocked).not.toHaveBeenCalled();
    });
  });

  it('does not retry or warn when a blocked play settles after the call ended', async () => {
    let rejectPlayback;
    audio.play.mockReturnValue(
      new Promise((_, reject) => {
        rejectPlayback = reject;
      })
    );

    ringtone.setSourceState('voice', { active: true });
    ringtone.setSourceState('voice', { active: false });
    rejectPlayback(
      Object.assign(new Error('blocked'), { name: 'NotAllowedError' })
    );
    await flushPromises();

    expect(permissionBlocked).not.toHaveBeenCalled();
    expect(eventTarget.addEventListener).not.toHaveBeenCalled();
  });

  it('reports non-policy playback failures without retry listeners', async () => {
    const decodeError = Object.assign(new Error('decode failed'), {
      name: 'NotSupportedError',
    });
    audio.play.mockRejectedValueOnce(decodeError);

    ringtone.setSourceState('voice', { active: true });
    await flushPromises();

    expect(captureException).toHaveBeenCalledWith(decodeError);
    expect(eventTarget.addEventListener).not.toHaveBeenCalled();
  });

  it('unregisters a source and releases the ringtone', async () => {
    ringtone.setSourceState('voice', { active: true });
    await flushPromises();

    ringtone.removeSource('voice');

    expect(audio.pause).toHaveBeenCalledTimes(1);
    expect(audio.currentTime).toBe(0);
  });
});
