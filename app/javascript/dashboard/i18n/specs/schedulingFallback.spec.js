import { describe, expect, it } from 'vitest';

import kk from '../locale/kk';
import ruScheduling from '../locale/ru/scheduling.json';

describe('Kazakh scheduling locale fallback', () => {
  it('uses the complete Russian scheduling catalog', () => {
    expect(kk.SCHEDULING).toEqual(ruScheduling.SCHEDULING);
    expect(kk.SCHEDULING.MEDELEMENT.CONFIRM_ACTION).toBe(
      'Подтвердить и отправить'
    );
    expect(kk.SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS).toBe('Нерабочее время');
  });
});
