import { describe, expect, it } from 'vitest';

import { formatSchedulingErrorMessage, toIntegerNumeric } from './shared';

describe('scheduling shared helpers', () => {
  it('formats the outside-working-hours API response for the user', () => {
    const error = {
      code: 'ERR_BAD_REQUEST',
      message: 'Request failed with status code 409',
      response: {
        data: {
          code: 'OUTSIDE_WORKING_HOURS',
          error: 'Appointment is outside working hours',
        },
        status: 409,
      },
    };
    const t = key =>
      key === 'SCHEDULING.ERRORS.OUTSIDE_WORKING_HOURS'
        ? 'Нерабочее время'
        : key;

    expect(formatSchedulingErrorMessage(error, t)).toBe('Нерабочее время');
  });

  it.each([
    [
      'MEDELEMENT_SERVICE_REQUIRED',
      'Select a service for Medelement',
      'Выберите услугу из каталога MedElement.',
    ],
    [
      'MEDELEMENT_SERVICE_UNMAPPED',
      'Selected services must be linked to Medelement',
      'Выбранная услуга не связана с MedElement.',
    ],
  ])('localizes the %s API response', (code, message, translation) => {
    const error = {
      response: {
        data: { code, error: message },
        status: 422,
      },
    };
    const t = key => (key === `SCHEDULING.ERRORS.${code}` ? translation : key);

    expect(formatSchedulingErrorMessage(error, t)).toBe(translation);
  });

  describe('toIntegerNumeric', () => {
    it('accepts integer values and decimal zero values', () => {
      expect(toIntegerNumeric(1000, 'amount')).toBe(1000);
      expect(toIntegerNumeric(1000.0, 'amount')).toBe(1000);
      expect(toIntegerNumeric('1000', 'amount')).toBe(1000);
      expect(toIntegerNumeric('1000.0', 'amount')).toBe(1000);
      expect(toIntegerNumeric('1000.00', 'amount')).toBe(1000);
    });

    it('rejects non-integer decimal values without truncating them', () => {
      expect(() => toIntegerNumeric(1000.5, 'amount')).toThrow(
        'amount must be an integer'
      );
      expect(() => toIntegerNumeric('1000.50', 'amount')).toThrow(
        'amount must be an integer'
      );
    });

    it('rejects invalid numeric values', () => {
      expect(() =>
        toIntegerNumeric(Number.POSITIVE_INFINITY, 'amount')
      ).toThrow('amount must be an integer');
      expect(() => toIntegerNumeric('abc', 'amount')).toThrow(
        'amount must be an integer'
      );
    });
  });
});
