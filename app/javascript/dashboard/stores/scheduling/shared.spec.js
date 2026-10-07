import { describe, expect, it } from 'vitest';

import enScheduling from '../../i18n/locale/en/scheduling.json';
import kkScheduling from '../../i18n/locale/kk/scheduling.json';
import ruScheduling from '../../i18n/locale/ru/scheduling.json';
import { formatSchedulingErrorMessage, toIntegerNumeric } from './shared';

const lookupMessage = (messages, key) =>
  key.split('.').reduce((node, part) => node?.[part], messages);

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
    [
      'MEDELEMENT_CANCELLATION_RESOLUTION_UNAVAILABLE',
      'The original reception has changed',
      'Исходный приём изменился. Требуется ручная проверка.',
    ],
    [
      'MEDELEMENT_CANCELLATION_NOT_VERIFIED',
      'Removal is not verified',
      'Удаление приёма в MedElement не подтверждено.',
    ],
    [
      'MEDELEMENT_CANCELLATION_CHECK_FAILED',
      'Provider lookup failed',
      'Не удалось проверить удаление в MedElement.',
    ],
    [
      'MEDELEMENT_CANCELLATION_RECORD_PROTECTED',
      'The cancellation record must be retained',
      'Запись об отмене нужно сохранить для синхронизации.',
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

  it.each([
    ['en', enScheduling],
    ['ru', ruScheduling],
    ['kk', kkScheduling],
  ])(
    'localizes an already linked MedElement reception in %s',
    (_locale, messages) => {
      const error = {
        response: {
          data: {
            code: 'MEDELEMENT_RECEPTION_ALREADY_LINKED',
            error:
              'The appointment is already linked to a Medelement reception or requires verification',
          },
          status: 409,
        },
      };
      const t = key => lookupMessage(messages, key) ?? key;
      const translation =
        messages.SCHEDULING.ERRORS.MEDELEMENT_RECEPTION_ALREADY_LINKED;

      expect(translation).toEqual(expect.any(String));
      expect(formatSchedulingErrorMessage(error, t)).toBe(translation);
    }
  );

  it.each([
    'APPOINTMENT_SLOT_UNAVAILABLE',
    'MEDELEMENT_AVAILABILITY_UNVERIFIED',
    'MEDELEMENT_PATIENT_PHONE_INVALID',
    'MEDELEMENT_CABINET_REQUIRED',
  ])('shows a Russian message for %s', code => {
    const error = {
      response: {
        data: { code, error: 'Provider scheduling request failed' },
        status: 422,
      },
    };
    const t = key => lookupMessage(ruScheduling, key) ?? key;

    expect(formatSchedulingErrorMessage(error, t)).toBe(
      ruScheduling.SCHEDULING.ERRORS[code]
    );
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
