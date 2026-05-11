import { describe, expect, it } from 'vitest';

import { normalizePromptPreviewText } from '../captainPromptPreview';

describe('normalizePromptPreviewText', () => {
  it('keeps normal compiled prompts unchanged', () => {
    expect(
      normalizePromptPreviewText('# Title\nUse "quotes" and tool://links.')
    ).toBe('# Title\nUse "quotes" and tool://links.');
  });

  it('decodes JSON-style escaped prompt text for readable UI preview', () => {
    expect(
      normalizePromptPreviewText(
        '# Title\\nUse \\"quotes\\" and https:\\/\\/example.com\\/docs'
      )
    ).toBe('# Title\nUse "quotes" and https://example.com/docs');
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
});
