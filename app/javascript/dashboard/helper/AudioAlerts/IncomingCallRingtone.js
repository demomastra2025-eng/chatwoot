import * as Sentry from '@sentry/vue';
import { useAlert } from 'dashboard/composables';

import {
  incomingCallRingtoneUrl,
  resolveIncomingCallRingtone,
} from './ringtone';

const RINGTONE_VOLUME = 0.8;
const SOUND_PERMISSION_ALERT_DURATION = 10000;

const showSoundPermissionAlert = () =>
  useAlert(
    'PROFILE_SETTINGS.FORM.AUDIO_NOTIFICATIONS_SECTION.SOUND_PERMISSION_ERROR',
    { usei18n: true, duration: SOUND_PERMISSION_ALERT_DURATION }
  );

export class IncomingCallRingtone {
  constructor({
    audioFactory = () => new Audio(),
    eventTarget = typeof document === 'undefined' ? null : document,
    captureException = Sentry.captureException,
    onPermissionBlocked = showSoundPermissionAlert,
  } = {}) {
    this.audioFactory = audioFactory;
    this.eventTarget = eventTarget;
    this.captureException = captureException;
    this.onPermissionBlocked = onPermissionBlocked;
    this.sources = new Map();
    this.audio = null;
    this.audioTone = null;
    this.isPlaying = false;
    this.playPromise = null;
    this.retryHandler = null;
    this.hasWarnedSoundPermission = false;
  }

  setSourceState(sourceId, { active = false, tone } = {}) {
    if (!sourceId) return;

    this.sources.set(sourceId, {
      active: Boolean(active),
      tone: resolveIncomingCallRingtone(tone),
    });
    this.syncPlayback();
  }

  removeSource(sourceId) {
    this.sources.delete(sourceId);
    this.syncPlayback();
  }

  activeTone() {
    return (
      [...this.sources.values()].find(source => source.active)?.tone || null
    );
  }

  ensureAudio(tone) {
    const resolvedTone = resolveIncomingCallRingtone(tone);
    if (this.audio && this.audioTone === resolvedTone) return this.audio;

    this.stopPlayback();
    const audio = this.audioFactory();
    audio.src = incomingCallRingtoneUrl(resolvedTone);
    audio.loop = true;
    audio.preload = 'auto';
    audio.volume = RINGTONE_VOLUME;
    this.audio = audio;
    this.audioTone = resolvedTone;
    return audio;
  }

  syncPlayback() {
    const tone = this.activeTone();
    if (!tone) {
      this.stopPlayback();
      return;
    }

    const audio = this.ensureAudio(tone);
    if (this.isPlaying || this.playPromise) return;

    let playResult;
    try {
      playResult = audio.play();
    } catch (error) {
      this.handlePlaybackError(error);
      return;
    }

    const currentPlayPromise = Promise.resolve(playResult);
    this.playPromise = currentPlayPromise;
    currentPlayPromise
      .then(() => {
        if (this.playPromise === currentPlayPromise) this.playPromise = null;
        if (this.audio !== audio || !this.activeTone()) {
          audio.pause();
          audio.currentTime = 0;
          return;
        }
        this.isPlaying = true;
      })
      .catch(error => {
        if (this.playPromise === currentPlayPromise) this.playPromise = null;
        this.isPlaying = false;
        if (this.audio !== audio || !this.activeTone()) return;
        this.handlePlaybackError(error);
      });
  }

  handlePlaybackError(error) {
    if (error?.name === 'NotAllowedError') {
      if (!this.hasWarnedSoundPermission) {
        this.hasWarnedSoundPermission = true;
        this.onPermissionBlocked();
      }
      this.armPlaybackRetry();
      return;
    }
    this.captureException(error);
  }

  armPlaybackRetry() {
    if (!this.eventTarget || this.retryHandler) return;

    this.retryHandler = () => {
      this.clearPlaybackRetry();
      this.syncPlayback();
    };
    this.eventTarget.addEventListener('pointerdown', this.retryHandler, {
      once: true,
    });
    this.eventTarget.addEventListener('keydown', this.retryHandler, {
      once: true,
    });
  }

  clearPlaybackRetry() {
    if (!this.eventTarget || !this.retryHandler) return;

    this.eventTarget.removeEventListener('pointerdown', this.retryHandler);
    this.eventTarget.removeEventListener('keydown', this.retryHandler);
    this.retryHandler = null;
  }

  stopPlayback() {
    this.clearPlaybackRetry();
    this.playPromise = null;
    this.isPlaying = false;
    if (!this.audio) return;

    this.audio.pause();
    this.audio.currentTime = 0;
  }
}

export default new IncomingCallRingtone();
