import { readdirSync, readFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import en from '../locale/en';
import kk from '../locale/kk';
import ru from '../locale/ru';
import knownMissing from './translationKeys.knownMissing.json';

// A literal key passed to t() / $t() that is absent from the locale files
// shows up on screen as the raw key. This guard statically extracts every
// literal key used in the dashboard source and fails when one is missing in
// ru, en or kk (dynamic keys built at runtime are out of reach).
//
// translationKeys.knownMissing.json lists the gaps that existed when the guard
// was added. They are only tolerated, never extended: a new missing key fails
// the test. Remove an entry once the key is added to the locale files.
const DASHBOARD_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const SKIPPED_DIRS = new Set([
  'locale',
  'node_modules',
  'specs',
  '__tests__',
  '__mocks__',
  'fixtures',
]);
const SKIPPED_FILES = /\.(spec|test|story)\./;
const SOURCE_FILES = /\.(vue|js)$/;

// t('A.B'), $t("A.B"), i18n.t(`A.B`), tc(...): the key must be a plain literal.
const LITERAL_KEY =
  /(?<![\w$])\$?tc?\(\s*(['"`])([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+)\1/g;

const extractKeys = source =>
  [...source.matchAll(LITERAL_KEY)].map(match => match[2]);

const sourceFiles = dir =>
  readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = resolve(dir, entry.name);
    if (entry.isDirectory()) {
      return SKIPPED_DIRS.has(entry.name) ? [] : sourceFiles(path);
    }
    return SOURCE_FILES.test(entry.name) && !SKIPPED_FILES.test(entry.name)
      ? [path]
      : [];
  });

const collectUsedKeys = () => {
  const used = new Map();
  sourceFiles(DASHBOARD_DIR).forEach(file => {
    extractKeys(readFileSync(file, 'utf8')).forEach(key => {
      if (!used.has(key)) used.set(key, new Set());
      used.get(key).add(relative(DASHBOARD_DIR, file).replaceAll('\\', '/'));
    });
  });
  return used;
};

const leafPaths = (value, path = '', out = new Set()) => {
  if (value && typeof value === 'object') {
    Object.entries(value).forEach(([key, child]) =>
      leafPaths(child, path ? `${path}.${key}` : key, out)
    );
  } else if (typeof value === 'string') {
    out.add(path);
  }
  return out;
};

const usedKeys = collectUsedKeys();

describe('dashboard translation keys', () => {
  it('extracts literal keys only', () => {
    expect(
      extractKeys(`
        t('A.B') $t("C.D_E", { n: 1 }) i18n.t(\`F.G\`) tc('H.I', 2)
        t(\`J.\${suffix}\`) t(variable) format('K.L') t('NOSEGMENT')
      `)
    ).toEqual(['A.B', 'C.D_E', 'F.G', 'H.I']);
  });

  it('scans the dashboard source', () => {
    expect(usedKeys.size).toBeGreaterThan(1000);
    expect(usedKeys.get('GENERAL_SETTINGS.BACK')).toBeDefined();
  });

  it.each([
    ['ru', ru],
    ['en', en],
    ['kk', kk],
  ])('has every literal key in %s', (locale, messages) => {
    const present = leafPaths(messages);
    const tolerated = new Set(knownMissing[locale]);

    const missing = [...usedKeys.keys()]
      .filter(key => !present.has(key) && !tolerated.has(key))
      .sort()
      .map(key => `${key}  <- ${[...usedKeys.get(key)].sort()[0]}`);

    expect(missing).toEqual([]);
  });
});
