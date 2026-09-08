import { describe, expect, it } from 'vitest';

import en from '../locale/en/crm.json';
import kk from '../locale/kk/crm.json';
import ru from '../locale/ru/crm.json';

const locales = { en, kk, ru };
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
  it.each(Object.entries(locales))(
    'defines every task catalog label for %s',
    (_locale, messages) => {
      const crm = messages.CRM;

      expect(crm.GENERAL.EDIT).toBeTruthy();
      expect(crm.TASKS.OUTCOME.other).toBeTruthy();
      expect(crm.SETTINGS.TASK_SETTINGS.TITLE).toBeTruthy();
      catalogKeys.forEach(key => {
        expect(crm.SETTINGS.TASK_CATALOGS[key]).toBeTruthy();
      });
    }
  );
});
