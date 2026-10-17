import { describe, it, expect } from 'vitest';
import {
  extractNormalizedReactions,
  getCurrentUserReactionEmoji,
} from './messageReactions';

describe('messageReactions helpers', () => {
  it('groups WhatsApp reactions and identifies current user reaction', () => {
    const contentAttributes = {
      whatsappReactions: {
        77010000000: { emoji: '❤️', timestamp: 1700000000 },
        business: {
          emoji: '❤️',
          userId: 15,
          userName: 'Айгерим',
          timestamp: 1700000005,
        },
        77020000000: { emoji: '👍', timestamp: 1700000010 },
      },
    };

    const result = extractNormalizedReactions({
      contentAttributes,
      currentUserId: 15,
    });

    expect(result).toEqual([
      {
        key: '❤️',
        emoji: '❤️',
        count: 2,
        reactedByMe: true,
        actors: ['Айгерим'],
        interactive: true,
      },
      {
        key: '👍',
        emoji: '👍',
        count: 1,
        reactedByMe: false,
        actors: [],
        interactive: true,
      },
    ]);
    expect(getCurrentUserReactionEmoji(contentAttributes, 15)).toBe('❤️');
  });

  it('normalizes Telegram reactions including chosen, custom, and paid reactions', () => {
    const contentAttributes = {
      telegram_reactions: {
        results: [
          { count: 3, chosen: true, reaction: { emoji: '🔥' } },
          {
            count: 1,
            chosen: false,
            reaction: { type: 'custom_emoji', custom_emoji_id: '555' },
          },
          { count: 2, chosen: false, reaction: { type: 'paid' } },
        ],
      },
    };

    const result = extractNormalizedReactions({
      contentAttributes,
      currentUserId: 15,
      t: key => key,
    });

    expect(result).toHaveLength(3);
    expect(result[0]).toMatchObject({
      emoji: '🔥',
      count: 3,
      reactedByMe: true,
      interactive: true,
    });
    expect(result[1]).toMatchObject({
      emoji: '✨',
      label: 'CONVERSATION.TELEGRAM.CUSTOM_EMOJI',
      count: 1,
      interactive: false,
    });
    expect(result[2]).toMatchObject({
      emoji: '⭐',
      label: 'CONVERSATION.TELEGRAM.PAID_REACTION',
      count: 2,
      interactive: false,
    });
    expect(getCurrentUserReactionEmoji(contentAttributes, 15)).toBe('🔥');
  });

  it('falls back to agentReactions when channel-specific maps are empty', () => {
    const contentAttributes = {
      agent_reactions: {
        'user:42': {
          emoji: '🙏',
          user_id: 42,
          user_name: 'Оператор Алия',
        },
      },
    };

    const result = extractNormalizedReactions({
      contentAttributes,
      currentUserId: 42,
    });

    expect(result).toEqual([
      {
        key: '🙏',
        emoji: '🙏',
        count: 1,
        reactedByMe: true,
        actors: ['Оператор Алия'],
        interactive: true,
      },
    ]);
    expect(getCurrentUserReactionEmoji(contentAttributes, 42)).toBe('🙏');
  });
});
