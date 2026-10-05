import { useMessageFormatter } from '../useMessageFormatter';

describe('useMessageFormatter', () => {
  let messageFormatter;

  beforeEach(() => {
    messageFormatter = useMessageFormatter();
  });

  describe('formatMessage', () => {
    it('should format a regular message correctly', () => {
      const message = 'This is a [test](https://example.com) message';
      const result = messageFormatter.formatMessage(message, false, false);
      expect(result).toContain('<a href="https://example.com"');
      expect(result).toContain('class="link"');
    });

    it('should format a tweet correctly', () => {
      const message = '@user #hashtag';
      const result = messageFormatter.formatMessage(message, true, false);
      expect(result).toContain('<a href="http://twitter.com/user"');
      expect(result).toContain('<a href="https://twitter.com/hashtag/hashtag"');
    });

    it('should not format mentions and hashtags for private notes', () => {
      const message = '@user #hashtag';
      const result = messageFormatter.formatMessage(message, false, true);
      expect(result).not.toContain('<a href="http://twitter.com/user"');
      expect(result).not.toContain(
        '<a href="https://twitter.com/hashtag/hashtag"'
      );
    });

    it('should disable link formatting when linkify is false', () => {
      const message = 'Check https://example.com and {{user.id}}';
      const result = messageFormatter.formatMessage(
        message,
        false,
        false,
        false
      );
      expect(result).not.toContain('<a href="https://example.com"');
      expect(result).toContain('{{user.id}}');
    });
  });

  describe('truncateMessage', () => {
    it('should not truncate short messages', () => {
      const message = 'Short message';
      const result = messageFormatter.truncateMessage(message);
      expect(result).toBe(message);
    });

    it('should truncate long messages', () => {
      const message = 'A'.repeat(150);
      const result = messageFormatter.truncateMessage(message);
      expect(result.length).toBe(100);
      expect(result.endsWith('...')).toBe(true);
    });
  });

  describe('highlightContent', () => {
    it('should highlight search term in content', () => {
      const content = 'This is a test message';
      const searchTerm = 'test';
      const highlightClass = 'highlight';
      const result = messageFormatter.highlightContent(
        content,
        searchTerm,
        highlightClass
      );
      expect(result.trim()).toBe(
        'This is a <span class="highlight">test</span> message'
      );
    });

    it('should handle special characters in search term', () => {
      const content = 'This (message) contains [special] characters';
      const searchTerm = '(message)';
      const highlightClass = 'highlight';
      const result = messageFormatter.highlightContent(
        content,
        searchTerm,
        highlightClass
      );
      expect(result.trim()).toBe(
        'This <span class="highlight">(message)</span> contains [special] characters'
      );
    });

    it('does not treat е and ё as one letter unless asked to', () => {
      const result = messageFormatter.highlightContent(
        'Нужен приём врача',
        'прием',
        'highlight'
      );

      expect(result.trim()).toBe('Нужен приём врача');
    });

    it('highlights е and ё as the same letter when asked to, in both directions and with the case ignored', () => {
      const options = { yoInsensitive: true };

      expect(
        messageFormatter
          .highlightContent('Нужен приём врача', 'прием', 'highlight', options)
          .trim()
      ).toBe('Нужен <span class="highlight">приём</span> врача');
      expect(
        messageFormatter
          .highlightContent('Нужен ПРИЕМ врача', 'приём', 'highlight', options)
          .trim()
      ).toBe('Нужен <span class="highlight">ПРИЕМ</span> врача');
    });

    it('still escapes the special characters when е and ё are unified', () => {
      const result = messageFormatter.highlightContent(
        'Счёт (VIP) [1]',
        'счет (vip)',
        'highlight',
        { yoInsensitive: true }
      );

      expect(result.trim()).toBe(
        '<span class="highlight">Счёт (VIP)</span> [1]'
      );
    });
  });
});
