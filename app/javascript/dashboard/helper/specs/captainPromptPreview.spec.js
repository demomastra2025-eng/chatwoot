import { describe, expect, it } from 'vitest';

import { normalizePromptPreviewText } from '../captainPromptPreview';

describe('normalizePromptPreviewText', () => {
  it('keeps normal compiled prompts unchanged', () => {
    expect(
      normalizePromptPreviewText('# Title\nUse "quotes" and tool://links.')
    ).toBe('# Title\nUse "quotes" and tool://links.');
  });

  it('preserves literal escapes written in the main prompt', () => {
    expect(
      normalizePromptPreviewText(
        '# Title\\nUse \\"quotes\\" and https:\\/\\/example.com\\/docs'
      )
    ).toBe('# Title\\nUse \\"quotes\\" and https:\\/\\/example.com\\/docs');
  });

  it('decodes a fully JSON-encoded string payload', () => {
    expect(
      normalizePromptPreviewText('"# Title\\n{\\"response\\":\\"ok\\"}"')
    ).toBe('# Title\n{"response":"ok"}');
  });

  it('returns an empty string for nullish values', () => {
    expect(normalizePromptPreviewText(null)).toBe('');
    expect(normalizePromptPreviewText(undefined)).toBe('');
  });

  it('keeps paragraph and list spacing without adding blank lines', () => {
    const prompt =
      'First paragraph\r\nSecond line\r\n\r\n- First item\r\n- Second item';
    expect(normalizePromptPreviewText(prompt)).toBe(
      'First paragraph\nSecond line\n\n- First item\n- Second item'
    );
  });
});
