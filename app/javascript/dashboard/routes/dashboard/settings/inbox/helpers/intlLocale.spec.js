import { describe, expect, it } from 'vitest';

import { getIntlLocale, getLanguageName } from './intlLocale';

describe('getIntlLocale', () => {
  it('keeps a language Intl knows and turns underscores into dashes', () => {
    expect(getIntlLocale('ru')).toBe('ru');
    expect(getIntlLocale('kk')).toBe('kk');
    expect(getIntlLocale('pt_BR')).toBe('pt-BR');
  });

  it('falls back to the base language, then to English', () => {
    expect(getIntlLocale('ru_RU')).toBe('ru-RU');
    expect(getIntlLocale('xx_YY')).toBe('en');
    expect(getIntlLocale('')).toBe('en');
    expect(getIntlLocale(undefined)).toBe('en');
    expect(getIntlLocale('not a locale at all')).toBe('en');
  });
});

describe('getLanguageName', () => {
  it('names a language in the language of the interface', () => {
    expect(getLanguageName('ru', 'ru')).toBe('Русский');
    expect(getLanguageName('en', 'ru')).toBe('Английский');
    expect(getLanguageName('ru', 'en')).toBe('Russian');
  });

  it('understands WhatsApp codes with an underscore', () => {
    expect(getLanguageName('en_US', 'ru')).toMatch(/^[А-ЯЁ]/);
    expect(getLanguageName('en_US', 'ru')).not.toContain('en_US');
    expect(getLanguageName('pt_BR', 'en')).toContain('Portuguese');
  });

  it('shows the code when Intl does not know the language', () => {
    expect(getLanguageName('xx', 'ru')).toBe('xx');
    expect(getLanguageName('definitely not a code', 'ru')).toBe(
      'definitely not a code'
    );
  });

  it('is empty without a code', () => {
    expect(getLanguageName('', 'ru')).toBe('');
    expect(getLanguageName(null, 'ru')).toBe('');
  });
});
