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

  it('names the reminder type consistently in each locale', () => {
    const crm = locale =>
      JSON.parse(readFileSync(resolve(LOCALE_DIR, locale, 'crm.json'), 'utf8'))
        .CRM;

    expect(crm('en').TASKS.ACTIVITY_TYPE.touch).toBe('Reminder');
    expect(crm('kk').TASKS.ACTIVITY_TYPE.touch).toBe('Еске салу');
    expect(crm('ru').TASKS.ACTIVITY_TYPE.touch).toBe('Напоминание');
  });
});

// Display names are also seeded into the database (task types, outcomes,
// statuses) by the backend; the locale files above cannot catch those.
describe('reminder wording in seeded catalog data', () => {
  const REPO_ROOT = resolve(LOCALE_DIR, '../../../../..');
  const read = path => readFileSync(resolve(REPO_ROOT, path), 'utf8');

  it.each(['ru', 'en', 'kk'])(
    'the %s seed names never contain «Касание» or "touch"',
    locale => {
      const names = read(`config/locales/crm_task_catalogs.${locale}.yml`)
        .split('\n')
        .filter(line => /^\s{8}\w+:/.test(line))
        .map(line => line.replace(/^\s+\w+:\s*/, ''));

      expect(names.length).toBeGreaterThan(20);
      expect(names.filter(name => TOUCH_WORDING.test(name))).toEqual([]);
    }
  );

  it('the provisioner seeds no hard-coded display names', () => {
    const provisioner = read('app/services/crm/task_catalogs/provisioner.rb');
    const definitions = provisioner.split('TASK_OUTCOMES')[0];

    expect(definitions).not.toMatch(/name:/);
    expect(provisioner).not.toMatch(/humanize/);
    expect(provisioner).not.toMatch(/name:\s*'Touch'/i);
  });
});
