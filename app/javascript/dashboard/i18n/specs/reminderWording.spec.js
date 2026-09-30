import { readdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// The owner's rule: the word «Касание» (en "touch", kk «жанасу») must not
// reach users anywhere in the dashboard; the entity is called «Напоминание»
// (en "reminder", kk «еске салу»). Translation keys keep their old names.
const LOCALE_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../locale'
);

const flatten = (value, path, out) => {
  if (value && typeof value === 'object') {
    Object.entries(value).forEach(([key, child]) =>
      flatten(child, path ? `${path}.${key}` : key, out)
    );
  } else if (typeof value === 'string') {
    out.push([path, value]);
  }
  return out;
};

const localeValues = locale =>
  readdirSync(resolve(LOCALE_DIR, locale))
    .filter(file => file.endsWith('.json'))
    .flatMap(file =>
      flatten(
        JSON.parse(readFileSync(resolve(LOCALE_DIR, locale, file), 'utf8')),
        file,
        []
      )
    );

// "get in touch" is an unrelated English idiom.
const withoutIdioms = value => value.replace(/get in touch/gi, '');
const TOUCH_WORDING = /касан|жанас|\btouch(es|ed|ing)?\b/i;

describe('reminder wording in the dashboard locales', () => {
  it.each(['ru', 'en', 'kk'])(
    '%s never shows «Касание» or "touch" to users',
    locale => {
      const offenders = localeValues(locale).filter(([, value]) =>
        TOUCH_WORDING.test(withoutIdioms(value))
      );

      expect(offenders).toEqual([]);
    }
  );

  it('kk reminder texts are Kazakh, not Russian', () => {
    const offenders = localeValues('kk').filter(([, value]) =>
      /напомин/i.test(value)
    );

    expect(offenders).toEqual([]);
  });
});
