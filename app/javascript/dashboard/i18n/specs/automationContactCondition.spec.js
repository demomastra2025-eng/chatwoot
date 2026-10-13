import { describe, expect, it } from 'vitest';

import { AUTOMATIONS } from 'dashboard/routes/dashboard/settings/automation/constants';
import en from '../locale/en/automation.json';
import kk from '../locale/kk/automation.json';
import ru from '../locale/ru/automation.json';

const LOCALES = { ru, en, kk };

const textAt = (messages, path) =>
  path.split('.').reduce((node, key) => node?.[key], messages);

const contactCondition = AUTOMATIONS.conversation_created.conditions.find(
  ({ key }) => key === 'contact_id'
);

describe('automation contact condition texts', () => {
  it.each(Object.entries(LOCALES))('are all present in %s', (_, messages) => {
    const paths = [
      `AUTOMATION.ATTRIBUTES.${contactCondition.name}`,
      contactCondition.searchPlaceholderKey,
      ...Object.values(contactCondition.operatorLabelKeys),
      'AUTOMATION.CONTACT_CONDITION.DELETED',
    ];

    paths.forEach(path => {
      expect(textAt(messages, path), path).toEqual(expect.any(String));
      expect(textAt(messages, path), path).not.toBe('');
    });
  });

  it('reads "является / не является" for the operators in Russian', () => {
    const { equal_to: equalTo, not_equal_to: notEqualTo } =
      contactCondition.operatorLabelKeys;

    expect(textAt(ru, equalTo)).toBe('является');
    expect(textAt(ru, notEqualTo)).toBe('не является');
    expect(textAt(ru, 'AUTOMATION.ATTRIBUTES.CONTACT')).toBe('Контакт');
  });

  it('tells which contact was deleted', () => {
    Object.values(LOCALES).forEach(messages => {
      expect(messages.AUTOMATION.CONTACT_CONDITION.DELETED).toContain('{id}');
    });
  });

  it('is offered for conversation, message and appointment events only', () => {
    const withContact = Object.entries(AUTOMATIONS)
      .filter(([, { conditions }]) =>
        conditions.some(({ key }) => key === 'contact_id')
      )
      .map(([eventName]) => eventName);

    expect(withContact.sort()).toEqual(
      [
        'appointment_cancelled',
        'appointment_completed',
        'appointment_created',
        'appointment_rescheduled',
        'appointment_updated',
        'conversation_created',
        'conversation_opened',
        'conversation_pending',
        'conversation_resolved',
        'conversation_transferred_to_ai',
        'conversation_updated',
        'message_created',
      ].sort()
    );
  });
});
