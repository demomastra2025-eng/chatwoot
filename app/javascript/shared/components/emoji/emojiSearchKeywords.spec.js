import { describe, it, expect } from 'vitest';
import emojis from './emojisGroup.json';
import {
  enrichEmojiCategories,
  matchesEmojiSearch,
  getCategoryLabelKey,
} from './emojiSearchKeywords';

describe('emojiSearchKeywords', () => {
  const enriched = enrichEmojiCategories(emojis);
  const allEmojis = enriched.flatMap(category => category.emojis);

  it('adds modern missing Unicode emojis like pink heart and stethoscope', () => {
    expect(allEmojis.some(item => item.emoji === '🩷')).toBe(true);
    expect(allEmojis.some(item => item.emoji === '🩺')).toBe(true);
    expect(allEmojis.some(item => item.emoji === '🫡')).toBe(true);
  });

  it('matches emojis by Russian, Kazakh, and English keywords', () => {
    const fire = allEmojis.find(item => item.emoji === '🔥');
    const heart = allEmojis.find(
      item => item.emoji.replace(/\uFE0F/g, '') === '❤'
    );
    const foldedHands = allEmojis.find(item => item.emoji === '🙏');
    const stethoscope = allEmojis.find(item => item.emoji === '🩺');

    expect(matchesEmojiSearch(fire, 'огонь')).toBe(true);
    expect(matchesEmojiSearch(fire, 'от')).toBe(true);
    expect(matchesEmojiSearch(fire, 'fire')).toBe(true);

    expect(matchesEmojiSearch(heart, 'сердце')).toBe(true);
    expect(matchesEmojiSearch(heart, 'жүрек')).toBe(true);

    expect(matchesEmojiSearch(foldedHands, 'спасибо')).toBe(true);
    expect(matchesEmojiSearch(foldedHands, 'рахмет')).toBe(true);

    expect(matchesEmojiSearch(stethoscope, 'врач')).toBe(true);
    expect(matchesEmojiSearch(stethoscope, 'дәрігер')).toBe(true);
  });

  it('maps category slugs to i18n keys', () => {
    expect(getCategoryLabelKey('frequently_used')).toBe(
      'EMOJI.CATEGORIES.FREQUENTLY_USED'
    );
    expect(getCategoryLabelKey('smileys_and_emotion')).toBe(
      'EMOJI.CATEGORIES.SMILEYS_AND_EMOTION'
    );
  });
});
