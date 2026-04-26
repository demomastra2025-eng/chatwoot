import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createI18n } from 'vue-i18n';

import initialMessages from '../initialMessages';
import {
  loadLocaleMessages,
  registerDashboardI18n,
  resolveLocaleCode,
  setDashboardLocale,
  setI18nLocale,
} from '../localeLoader';

describe('dashboard i18n lazy loading', () => {
  beforeEach(() => {
    registerDashboardI18n(null);
  });

  it('keeps only startup locales in the initial dashboard bundle', () => {
    expect(Object.keys(initialMessages).sort()).toEqual(['en', 'ru']);
  });

  it('loads non-startup locales on demand', async () => {
    const i18n = {
      availableLocales: ['en', 'ru'],
      setLocaleMessage: vi.fn(),
    };

    const locale = await loadLocaleMessages(i18n, 'pt-BR');

    expect(locale).toBe('pt_BR');
    expect(i18n.setLocaleMessage).toHaveBeenCalledWith(
      'pt_BR',
      expect.objectContaining({})
    );
  });

  it('sets vue-i18n composer locale refs after loading the locale', async () => {
    const i18n = {
      availableLocales: ['en', 'ru'],
      locale: { value: 'ru' },
      setLocaleMessage: vi.fn(),
    };

    const locale = await setI18nLocale(i18n, 'kk');

    expect(locale).toBe('kk');
    expect(i18n.locale.value).toBe('kk');
    expect(i18n.setLocaleMessage).toHaveBeenCalledWith(
      'kk',
      expect.objectContaining({})
    );
  });

  it('uses the registered runtime i18n instance for component locale changes', async () => {
    const i18n = {
      availableLocales: ['en', 'ru'],
      locale: { value: 'ru' },
      setLocaleMessage: vi.fn(),
    };

    registerDashboardI18n(i18n);

    const locale = await setDashboardLocale('pt-BR');

    expect(locale).toBe('pt_BR');
    expect(i18n.locale.value).toBe('pt_BR');
    expect(i18n.setLocaleMessage).toHaveBeenCalledWith(
      'pt_BR',
      expect.objectContaining({})
    );
  });

  it('works with the real vue-i18n legacy:false global composer', async () => {
    const i18n = createI18n({
      legacy: false,
      locale: 'ru',
      fallbackLocale: 'en',
      messages: initialMessages,
    });

    registerDashboardI18n(i18n.global);

    const locale = await setDashboardLocale('kk');

    expect(locale).toBe('kk');
    expect(i18n.global.locale.value).toBe('kk');
    expect(i18n.global.availableLocales).toContain('kk');
  });

  it('falls back to Russian for unsupported locales', () => {
    expect(resolveLocaleCode('unknown-locale')).toBe('ru');
  });
});
