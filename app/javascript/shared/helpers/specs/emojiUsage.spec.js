import { describe, it, expect, beforeEach } from 'vitest';
import { LocalStorage } from 'shared/helpers/localStorage';
import {
  FREQUENT_EMOJIS_STORAGE_KEY,
  FREQUENT_REACTIONS_STORAGE_KEY,
  DEFAULT_QUICK_REACTIONS,
  recordEmojiUsage,
  recordReactionUsage,
  getSortedStoredEmojis,
  getQuickReactions,
} from '../emojiUsage';

describe('emojiUsage helpers', () => {
  beforeEach(() => {
    LocalStorage.set(FREQUENT_EMOJIS_STORAGE_KEY, {});
    LocalStorage.set(FREQUENT_REACTIONS_STORAGE_KEY, {});
  });

  it('tracks and sorts frequently used emojis by count and recency', () => {
    recordEmojiUsage('😀');
    recordEmojiUsage('🔥');
    recordEmojiUsage('🔥');
    recordEmojiUsage('🩷');

    const sorted = getSortedStoredEmojis(FREQUENT_EMOJIS_STORAGE_KEY);
    expect(sorted[0]).toBe('🔥');
    expect(sorted).toContain('🩷');
    expect(sorted).toContain('😀');
  });

  it('returns default quick reactions when no custom usage is stored', () => {
    expect(getQuickReactions(6)).toEqual(DEFAULT_QUICK_REACTIONS.slice(0, 6));
  });

  it('promotes frequently used reactions to the front of quick reactions without duplicates', () => {
    recordReactionUsage('🩺');
    recordReactionUsage('🩺');
    recordReactionUsage('🎉');

    const quick = getQuickReactions(6);
    expect(quick).toHaveLength(6);
    expect(quick[0]).toBe('🩺');
    expect(quick[1]).toBe('🎉');
    expect(new Set(quick).size).toBe(6);
  });
});
