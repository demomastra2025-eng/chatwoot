import { describe, expect, it } from 'vitest';
import {
  formatStorageBytes,
  formatStorageDate,
  toIntlLocale,
} from './storageFormatters';

const RU_UNITS = { B: 'Б', KB: 'КБ', MB: 'МБ', GB: 'ГБ', TB: 'ТБ' };

describe('storageFormatters', () => {
  it('formats sizes with the user locale and localized unit labels', () => {
    expect(
      formatStorageBytes(1536, { locale: 'ru', unitLabels: RU_UNITS })
    ).toBe('1,5 КБ');
    expect(
      formatStorageBytes(1536, {
        locale: 'en',
        unitLabels: { KB: 'KB' },
      })
    ).toBe('1.5 KB');
    expect(
      formatStorageBytes(5 * 1024 ** 3, { locale: 'kk', unitLabels: RU_UNITS })
    ).toBe('5 ГБ');
  });

  it('formats empty and invalid sizes as zero bytes', () => {
    expect(formatStorageBytes(0, { locale: 'ru', unitLabels: RU_UNITS })).toBe(
      '0 Б'
    );
    expect(formatStorageBytes(null, { locale: 'en' })).toBe('0 B');
  });

  it('formats dates with the user locale instead of a fixed Russian format', () => {
    const value = '2026-10-05T14:30:00Z';

    expect(formatStorageDate(value, 'ru')).toBe('05.10.2026, 14:30');
    expect(formatStorageDate(value, 'en')).toBe('10/05/2026, 02:30 PM');
    expect(formatStorageDate(value, 'kk')).toBe('05.10.2026, 14:30');
  });

  it('keeps missing and invalid dates readable', () => {
    expect(formatStorageDate(null, 'en')).toBe('—');
    expect(formatStorageDate('not a date', 'en')).toBe('not a date');
  });

  it('maps vue-i18n locale codes to Intl locale tags', () => {
    expect(toIntlLocale('pt_BR')).toBe('pt-BR');
    expect(toIntlLocale(undefined)).toBe('en');
  });
});
