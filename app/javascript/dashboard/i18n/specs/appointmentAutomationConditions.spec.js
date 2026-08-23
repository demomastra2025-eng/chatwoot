import { describe, expect, it } from 'vitest';

import en from '../locale/en/automation.json';
import kkFilters from '../locale/kk/advancedFilters.json';
import kk from '../locale/kk/automation.json';
import ru from '../locale/ru/automation.json';

const EXPECTED_ATTRIBUTE_LABELS = {
  en: {
    APPOINTMENT_START_WEEKDAY: 'Appointment Start Weekday',
    APPOINTMENT_START_TIME: 'Appointment Start Time',
    APPOINTMENT_SERVICE: 'Service',
  },
  ru: {
    APPOINTMENT_START_WEEKDAY: 'День недели начала записи',
    APPOINTMENT_START_TIME: 'Время начала записи',
    APPOINTMENT_SERVICE: 'Услуга',
  },
  kk: {
    APPOINTMENT_START_WEEKDAY: 'Жазба басталатын апта күні',
    APPOINTMENT_START_TIME: 'Жазбаның басталу уақыты',
    APPOINTMENT_SERVICE: 'Қызмет',
  },
};

const LOCALES = { en, ru, kk };

describe('appointment automation condition translations', () => {
  it.each(Object.entries(LOCALES))(
    'provides real condition and weekday labels for %s',
    (locale, messages) => {
      expect(messages.AUTOMATION.ATTRIBUTES).toMatchObject(
        EXPECTED_ATTRIBUTE_LABELS[locale]
      );
      expect(Object.keys(messages.AUTOMATION.WEEKDAYS)).toEqual([
        '0',
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
      ]);
      expect(Object.values(messages.AUTOMATION.WEEKDAYS)).toHaveLength(7);
    }
  );

  it('uses real Kazakh labels for the exposed query and comparison operators', () => {
    expect(kkFilters.FILTER.QUERY_DROPDOWN_LABELS).toMatchObject({
      AND: 'ЖӘНЕ',
      OR: 'НЕМЕСЕ',
    });
    expect(kkFilters.FILTER.OPERATOR_LABELS).toMatchObject({
      equal_to: 'Тең',
      not_equal_to: 'Тең емес',
      is_greater_than: 'Үлкен',
      is_less_than: 'Кіші',
    });
  });
});
