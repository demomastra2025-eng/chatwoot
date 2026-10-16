import { describe, it, expect } from 'vitest';
import {
  emojiToAppleUnified,
  getAppleEmojiUrl,
  isJumboEmojiText,
  replaceEmojisWithAppleImages,
} from '../appleEmoji';

describe('appleEmoji helpers', () => {
  it('converts standard, unqualified BMP, keycap, flag, and modern emojis to Apple unified codes', () => {
    expect(emojiToAppleUnified('😀')).toBe('1f600');
    expect(emojiToAppleUnified('❤')).toBe('2764-fe0f');
    expect(emojiToAppleUnified('❤️')).toBe('2764-fe0f');
    expect(emojiToAppleUnified('🩷')).toBe('1fa77');
    expect(emojiToAppleUnified('🩺')).toBe('1fa7a');
    expect(emojiToAppleUnified('#️⃣')).toBe('0023-fe0f-20e3');
    expect(emojiToAppleUnified('🇰🇿')).toBe('1f1f0-1f1ff');
    expect(getAppleEmojiUrl('🔥')).toContain('/img/apple/64/1f525.png');
  });

  it('detects jumbo emoji messages (1 to 3 emojis only)', () => {
    expect(isJumboEmojiText('❤️')).toBe(true);
    expect(isJumboEmojiText('👍 🔥 🎉')).toBe(true);
    expect(isJumboEmojiText('👍 🔥 🎉 ❤️')).toBe(false);
    expect(isJumboEmojiText('Привет ❤️')).toBe(false);
  });

  it('replaces emojis in HTML with Apple img tags while preserving code blocks', () => {
    const html = '<p>Спасибо ❤️ <code>🔥</code></p>';
    const rendered = replaceEmojisWithAppleImages(html, { jumbo: false });
    expect(rendered).toContain('2764-fe0f.png');
    expect(rendered).toContain('alt="❤️"');
    expect(rendered).toContain('<code>🔥</code>');
  });
});
