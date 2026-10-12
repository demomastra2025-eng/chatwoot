import { existsSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

import {
  DEFAULT_AUDIO_ALERT_TYPE,
  DEFAULT_NOTIFICATION_TONE,
  NOTIFICATION_TONES,
  notificationToneUrl,
  resolveAudioAlertType,
  resolveNotificationTone,
} from './notificationSound';

const currentDir = dirname(fileURLToPath(import.meta.url));
const audioDir = resolve(currentDir, '../../../../../public/audio/dashboard');

describe('message notification tones', () => {
  it('offers exactly the supported tones in a fixed order', () => {
    expect(NOTIFICATION_TONES).toEqual([
      'ding',
      'ping',
      'duet',
      'bipbop',
      'signal',
      'softbell',
    ]);
  });

  it('defaults to bipbop', () => {
    expect(DEFAULT_NOTIFICATION_TONE).toBe('bipbop');
    expect(resolveNotificationTone()).toBe('bipbop');
    expect(resolveNotificationTone(null)).toBe('bipbop');
    expect(resolveNotificationTone('')).toBe('bipbop');
    expect(notificationToneUrl()).toBe('/audio/dashboard/bipbop.mp3');
  });

  it.each(NOTIFICATION_TONES)('keeps the saved tone %s', tone => {
    expect(resolveNotificationTone(tone)).toBe(tone);
    expect(notificationToneUrl(tone)).toBe(`/audio/dashboard/${tone}.mp3`);
  });

  it.each(['bell', 'chime', 'magic', 'drumroll', 'DING', '../ding', 42])(
    'plays the default for the removed or unknown tone %s',
    value => {
      expect(resolveNotificationTone(value)).toBe('bipbop');
      expect(notificationToneUrl(value)).toBe('/audio/dashboard/bipbop.mp3');
    }
  );

  it('has an audio file for every tone and no other file', () => {
    expect(existsSync(audioDir)).toBe(true);
    expect(readdirSync(audioDir).sort()).toEqual(
      NOTIFICATION_TONES.map(tone => `${tone}.mp3`).sort()
    );
  });
});

describe('message notification events', () => {
  it('defaults to assigned and unassigned conversations', () => {
    expect(DEFAULT_AUDIO_ALERT_TYPE).toBe('assigned+unassigned');
  });

  it.each([undefined, null, '', '  '])(
    'turns the missing value %j on by default',
    value => {
      expect(resolveAudioAlertType(value)).toBe('assigned+unassigned');
    }
  );

  it.each(['none', 'mine', 'all', 'assigned', 'notme+unassigned'])(
    'keeps the chosen value %s, an explicit none stays off',
    value => {
      expect(resolveAudioAlertType(value)).toBe(value);
    }
  );

  it('does not break on a value of an unexpected type', () => {
    expect(resolveAudioAlertType(false)).toBe('none');
    expect(resolveAudioAlertType(true)).toBe('none');
  });
});
