import { describe, expect, it } from 'vitest';

import kk from '../locale/kk';
import ruScheduling from '../locale/ru/scheduling.json';
import kkScheduling from '../locale/kk/scheduling.json';

describe('Kazakh scheduling locale fallback', () => {
  it('keeps the existing Kazakh scheduling fields and patient search catalog', () => {
    expect(kk.SCHEDULING).toMatchObject({
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
  it('loads Kazakh compact calendar labels from the full locale module and keeps untranslated fallbacks', () => {
    expect(kk.SCHEDULING.VIEWS).toEqual({
      CALENDAR: 'Күнтізбе',
      DAY: 'Күн',
      WEEK: 'Апта',
      MONTH: 'Ай',
      LIST: 'Тізім',
      KANBAN: 'Тақта',
    });
    expect(kk.SCHEDULING.TOOLBAR.RESOURCES_SELECTED).toBe(
      'Таңдалғаны: {count}'
    );
    expect(kk.SCHEDULING.TOOLBAR.FILTERS).toBe('Сүзгілер');
    expect(kk.SCHEDULING.TOOLBAR.PREVIOUS).toBe('Алдыңғы кезең');
    expect(kk.SCHEDULING.CALENDAR.SELECT_RESOURCES).toBe('Мамандарды таңдаңыз');
    expect(kk.SCHEDULING.CALENDAR.ALL_RESOURCES_UNAVAILABLE).toBe(
      'Барлық мамандар қолжетімсіз'
    );
    expect(kk.SCHEDULING.CALENDAR.NEW_APPOINTMENT).toBe(
      ruScheduling.SCHEDULING.CALENDAR.NEW_APPOINTMENT
    );
    expect(kk.SCHEDULING.TOOLBAR.RESOURCE_SEARCH).toBe(
      ruScheduling.SCHEDULING.TOOLBAR.RESOURCE_SEARCH
    );
    expect(kk.SCHEDULING.GENERAL.TODAY).toBe(
      ruScheduling.SCHEDULING.GENERAL.TODAY
    );
  });
});
