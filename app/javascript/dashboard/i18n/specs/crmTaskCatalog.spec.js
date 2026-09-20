import { describe, expect, it } from 'vitest';

import en from '../locale/en/crm.json';
import kk from '../locale/kk/crm.json';
import ru from '../locale/ru/crm.json';

const locales = { en, kk, ru };
const flattenLeaves = (value, prefix = '') =>
  Object.entries(value).reduce((result, [key, child]) => {
    const path = prefix ? `${prefix}.${key}` : key;

    if (child && typeof child === 'object' && !Array.isArray(child)) {
      return { ...result, ...flattenLeaves(child, path) };
    }

    result[path] = child;
    return result;
  }, {});

const interpolationTokens = value =>
  typeof value === 'string'
    ? [...value.matchAll(/\{([^{}]+)\}/g)].map(([, token]) => token).sort()
    : [];

const catalogKeys = [
  'ACTIVATE',
  'ACTIVE',
  'ADD_OUTCOME',
  'ADD_TYPE',
  'DEACTIVATE',
  'DEFAULT',
  'DESCRIPTION',
  'EDIT_OUTCOME',
  'EDIT_TYPE',
  'ICON',
  'ICON_OPTION',
  'INACTIVE',
  'NAME',
  'REQUIRES_NOTE',
  'SAVED',
  'TITLE',
];

describe('CRM task catalog locales', () => {
  it.each(['ru', 'kk'])(
    'keeps the complete CRM key and interpolation contract for %s',
    locale => {
      const englishLeaves = flattenLeaves(en.CRM);
      const localeLeaves = flattenLeaves(locales[locale].CRM);

      expect(Object.keys(localeLeaves).sort()).toEqual(
        Object.keys(englishLeaves).sort()
      );
      Object.entries(englishLeaves).forEach(([key, englishValue]) => {
        expect(interpolationTokens(localeLeaves[key]), key).toEqual(
          interpolationTokens(englishValue)
        );
      });
    }
  );

  it.each(Object.entries(locales))(
    'defines every task catalog label for %s',
    (_locale, messages) => {
      const crm = messages.CRM;

      expect(crm.GENERAL.EDIT).toBeTruthy();
      expect(crm.TASKS.LOADING_MORE).toBeTruthy();
      expect(crm.TASKS.RETRY_LOAD).toBeTruthy();
      expect(crm.TASKS.OUTCOME.other).toBeTruthy();
      expect(crm.SETTINGS.TASK_SETTINGS.TITLE).toBeTruthy();
      catalogKeys.forEach(key => {
        expect(crm.SETTINGS.TASK_CATALOGS[key]).toBeTruthy();
      });
    }
  );
});
