import { describe, expect, it } from 'vitest';

import kk from '../locale/kk';
import ruScheduling from '../locale/ru/scheduling.json';
import kkScheduling from '../locale/kk/scheduling.json';

describe('Kazakh scheduling locale fallback', () => {
  it('uses Russian scheduling except for the patient search catalog', () => {
    expect(kk.SCHEDULING).toEqual({
      ...ruScheduling.SCHEDULING,
      PATIENT_SEARCH: kkScheduling.SCHEDULING.PATIENT_SEARCH,
    });
    expect(kk.SCHEDULING.MEDELEMENT.CONFIRM_ACTION).toBe(
      'Подтвердить и отправить'
    );
    expect(kk.SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS).toBe('Нерабочее время');
  });
});
