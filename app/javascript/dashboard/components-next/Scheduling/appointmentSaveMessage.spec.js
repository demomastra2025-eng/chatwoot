import { describe, expect, it } from 'vitest';
import { createI18n } from 'vue-i18n';
import en from 'dashboard/i18n/locale/en/scheduling.json';
import ru from 'dashboard/i18n/locale/ru/scheduling.json';
import kk from 'dashboard/i18n/locale/kk/scheduling.json';
import {
  appointmentCrmLinkWarningMessage,
  appointmentProviderMoveMessage,
  appointmentSaveAlertMessage,
} from './appointmentSaveMessage';

describe('saved appointment CRM result', () => {
  const t = createI18n({
    legacy: false,
    locale: 'ru',
    messages: { en, ru, kk },
  }).global.t;

  it.each([
    {},
    { crmLinkResult: null },
    { crmLinkResult: { status: 'linked' } },
    { crmLinkResult: { status: 'failed' } },
  ])(
    'keeps a normal save successful without an unlinked result: %j',
    result => {
      expect(appointmentCrmLinkWarningMessage(result, t)).toBe('');
      expect(appointmentSaveAlertMessage(result, t)).toBe('Запись сохранена');
    }
  );

  it.each(['en', 'ru', 'kk'])(
    'localizes a saved booking warning in %s without showing an internal code or raw server text',
    locale => {
      const i18n = createI18n({
        legacy: false,
        locale,
        messages: { en, ru, kk },
      });
      const appointment = {
        crm_link_result: {
          status: 'not_linked',
          code: 'CRM_DEAL_SELECTION_REQUIRED',
          message: 'Raw backend message',
        },
      };
      const message = appointmentSaveAlertMessage(appointment, i18n.global.t);
      expect(message).toBe(
        { en, ru, kk }[locale].SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL
      );
      expect(message).not.toContain('Raw backend message');
      expect(message).not.toContain('CRM_DEAL_SELECTION_REQUIRED');
    }
  );

  it.each(['en', 'ru', 'kk'])(
    'says in %s that a MedElement reschedule is requested, not applied, until MedElement confirms it',
    locale => {
      const i18n = createI18n({
        legacy: false,
        locale,
        messages: { en, ru, kk },
      });
      const message = appointmentSaveAlertMessage(
        { providerMove: { state: 'pending' } },
        i18n.global.t
      );
      expect(message).toBe(
        { en, ru, kk }[locale].SCHEDULING.APPOINTMENT_FORM.MOVE_PENDING
      );
      expect(message).not.toBe(
        { en, ru, kk }[locale].SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE
      );
    }
  );

  it.each([
    { providerMove: { state: 'rejected' } },
    { providerMove: { state: 'needs_reconciliation' } },
    { providerMove: null },
  ])('keeps the ordinary save message when no move is waiting: %j', result => {
    expect(appointmentProviderMoveMessage(result, t)).toBe('');
    expect(appointmentSaveAlertMessage(result, t)).toBe('Запись сохранена');
  });

  it('explains missing CRM stage fields while retaining the saved appointment result', () => {
    const appointment = {
      crmLinkResult: {
        status: 'not_linked',
        code: 'DEAL_STAGE_REQUIRES_FIELDS',
      },
    };
    expect(appointmentSaveAlertMessage(appointment, t)).toBe(
      ru.SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL_REQUIRED_FIELDS
    );
  });
});
