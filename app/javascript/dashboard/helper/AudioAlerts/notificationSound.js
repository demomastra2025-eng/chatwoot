import { EVENT_TYPES } from 'dashboard/routes/dashboard/settings/profile/constants.js';

// Sounds of new-message notifications: /public/audio/dashboard/<tone>.mp3.
export const NOTIFICATION_TONES = Object.freeze([
  'ding',
  'ping',
  'duet',
  'bipbop',
  'signal',
  'softbell',
]);

export const DEFAULT_NOTIFICATION_TONE = 'bipbop';

const TONE_VALUES = new Set(NOTIFICATION_TONES);

// A saved tone that was removed from the list, or any unknown value, plays the
// default one. Nothing is written back to ui_settings.
export const resolveNotificationTone = value =>
  TONE_VALUES.has(value) ? value : DEFAULT_NOTIFICATION_TONE;

export const notificationToneUrl = value =>
  `/audio/dashboard/${resolveNotificationTone(value)}.mp3`;

// Users who never opened the sound settings (enable_audio_alerts is missing)
// hear new messages of their own and of unassigned conversations. An explicit
// 'none' stays off.
export const DEFAULT_AUDIO_ALERT_TYPE = [
  EVENT_TYPES.ASSIGNED,
  EVENT_TYPES.UNASSIGNED,
].join('+');

export const resolveAudioAlertType = value => {
  if (value === undefined || value === null) return DEFAULT_AUDIO_ALERT_TYPE;
  if (typeof value !== 'string') return 'none';
  return value.trim() ? value : DEFAULT_AUDIO_ALERT_TYPE;
};
