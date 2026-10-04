import en from 'dashboard/i18n/locale/en/designSystem.json';
import ru from 'dashboard/i18n/locale/ru/designSystem.json';
import kk from 'dashboard/i18n/locale/kk/designSystem.json';
import enIndex from 'dashboard/i18n/locale/en';
import ruIndex from 'dashboard/i18n/locale/ru';
import kkIndex from 'dashboard/i18n/locale/kk';

const sources = import.meta.glob('../*.vue', {
  query: '?raw',
  import: 'default',
  eager: true,
});

const flatten = (object, prefix = '') =>
  Object.entries(object).reduce((keys, [key, value]) => {
    const path = prefix ? `${prefix}.${key}` : key;
    return typeof value === 'object'
      ? { ...keys, ...flatten(value, path) }
      : { ...keys, [path]: value };
  }, {});

const locales = { en, ru, kk };

describe('design system i18n', () => {
  it('has the same keys in en, ru and kk', () => {
    const enKeys = Object.keys(flatten(en)).sort();
    expect(Object.keys(flatten(ru)).sort()).toEqual(enKeys);
    expect(Object.keys(flatten(kk)).sort()).toEqual(enKeys);
  });

  it('has no empty or untranslated Russian / Kazakh strings', () => {
    const enValues = flatten(en);
    ['ru', 'kk'].forEach(locale => {
      Object.entries(flatten(locales[locale])).forEach(([key, value]) => {
        expect(value.trim(), `${locale}.${key}`).not.toBe('');
        if (!/^\{\w+\}%$/.test(value)) {
          expect(value, `${locale}.${key}`).not.toBe(enValues[key]);
        }
      });
    });
  });

  it('is registered in every locale bundle', () => {
    [enIndex, ruIndex, kkIndex].forEach(bundle => {
      expect(bundle.DESIGN_SYSTEM).toBeDefined();
    });
  });

  it('defines every key the components use, in all three locales', () => {
    const used = new Set(
      Object.values(sources).flatMap(
        source => source.match(/DESIGN_SYSTEM\.[A-Z_.]+[A-Z]/g) || []
      )
    );
    // DsStatusDot builds its key from the status name
    ['GOOD', 'WARN', 'BAD', 'NEUTRAL'].forEach(status =>
      used.add(`DESIGN_SYSTEM.STATUS.${status}`)
    );
    used.delete('DESIGN_SYSTEM.STATUS');

    expect(used.size).toBeGreaterThan(10);
    Object.entries(locales).forEach(([locale, messages]) => {
      const keys = flatten(messages);
      used.forEach(key => {
        expect(keys[key], `${locale}: ${key}`).toBeTruthy();
      });
    });
  });

  it('never says Touch / Касание to users', () => {
    Object.values(locales).forEach(messages => {
      Object.values(flatten(messages)).forEach(value => {
        expect(value).not.toMatch(/touch|касани/i);
      });
    });
  });
});
