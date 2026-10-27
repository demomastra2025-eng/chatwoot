import { describe, expect, it } from 'vitest';

import kk from '../locale/kk';
import ruScheduling from '../locale/ru/scheduling.json';
import kkScheduling from '../locale/kk/scheduling.json';

describe('Kazakh scheduling locale fallback', () => {
  it('keeps the existing Kazakh scheduling fields and patient search catalog', () => {
    expect(kk.SCHEDULING).toEqual({
      ...ruScheduling.SCHEDULING,
      PATIENT_SEARCH: kkScheduling.SCHEDULING.PATIENT_SEARCH,
      CONTACT: {
        ...ruScheduling.SCHEDULING.CONTACT,
        ...kkScheduling.SCHEDULING.CONTACT,
      },
      ERRORS: {
        ...ruScheduling.SCHEDULING.ERRORS,
        ...kkScheduling.SCHEDULING.ERRORS,
      },
      APPOINTMENT_FORM: {
        ...ruScheduling.SCHEDULING.APPOINTMENT_FORM,
        ERRORS: {
          ...ruScheduling.SCHEDULING.APPOINTMENT_FORM.ERRORS,
          ...kkScheduling.SCHEDULING.APPOINTMENT_FORM.ERRORS,
        },
      },
    });
    expect(kk.SCHEDULING.MEDELEMENT.CONFIRM_ACTION).toBe(
      'Подтвердить и отправить'
    );
    expect(kk.SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS).toBe('Нерабочее время');
  });
});
