import { describe, expect, it } from 'vitest';

import kk from '../locale/kk';
import kkScheduling from '../locale/kk/scheduling.json';
import ruScheduling from '../locale/ru/scheduling.json';

const expectFallbackCatalog = (actual, base, overrides = {}) => {
  expect(Object.keys(actual).sort()).toEqual(Object.keys(base).sort());
  Object.entries(base).forEach(([key, value]) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      expectFallbackCatalog(actual[key], value, overrides[key] ?? {});
    } else {
      expect(actual[key]).toEqual(
        Object.hasOwn(overrides, key) ? overrides[key] : value
      );
      expect(typeof actual[key]).toBe('string');
      expect(actual[key].trim()).not.toBe('');
    }
  });
};

describe('Kazakh scheduling locale fallback', () => {
  it('retains the Russian catalog with Kazakh overrides', () => {
    expectFallbackCatalog(
      kk.SCHEDULING,
      ruScheduling.SCHEDULING,
      kkScheduling.SCHEDULING
    );
    expect(kk.SCHEDULING.MEDELEMENT.CONFIRM_ACTION).toBe(
      'Подтвердить и отправить'
    );
    expect(kk.SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS).toBe('Нерабочее время');
    expect(kk.SCHEDULING.CALENDAR.ALL_RESOURCES_UNAVAILABLE).toBe(
      'Барлық мамандар қолжетімсіз'
    );
  });
});
