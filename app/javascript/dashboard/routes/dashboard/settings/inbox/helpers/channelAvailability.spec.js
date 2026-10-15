import { describe, expect, it } from 'vitest';
import {
  CHANNEL_TILES,
  isChannelAvailable,
  isTileAvailable,
} from './channelAvailability';

describe('channelAvailability', () => {
  describe('isChannelAvailable', () => {
    it('offers everything when the account payload has no list (old cached copy)', () => {
      expect(isChannelAvailable(undefined, 'api')).toBe(true);
      expect(isChannelAvailable(null, 'twitter')).toBe(true);
    });

    it('offers a channel only when it is in the list', () => {
      expect(isChannelAvailable(['website', 'email'], 'email')).toBe(true);
      expect(isChannelAvailable(['website', 'email'], 'api')).toBe(false);
    });

    it('offers nothing for an empty list', () => {
      expect(isChannelAvailable([], 'website')).toBe(false);
    });
  });

  describe('isTileAvailable', () => {
    it('treats a plain tile as one channel of the same name', () => {
      expect(isTileAvailable(['voice'], 'voice')).toBe(true);
      expect(isTileAvailable(['voice'], 'website')).toBe(false);
    });

    it('keeps the WhatsApp tile while any of its three ways is available', () => {
      CHANNEL_TILES.whatsapp.forEach(way => {
        expect(isTileAvailable([way], 'whatsapp')).toBe(true);
      });
      expect(isTileAvailable(['website'], 'whatsapp')).toBe(false);
    });

    it('keeps the Telegram tile while the bot or the personal account is available', () => {
      expect(isTileAvailable(['telegram_bot'], 'telegram')).toBe(true);
      expect(isTileAvailable(['telegram_personal'], 'telegram')).toBe(true);
      expect(isTileAvailable(['website'], 'telegram')).toBe(false);
    });

    it('shows every tile when there is no list', () => {
      expect(isTileAvailable(undefined, 'whatsapp')).toBe(true);
      expect(isTileAvailable(undefined, 'api')).toBe(true);
    });
  });
});
