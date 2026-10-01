import { describe, expect, it } from 'vitest';

import ru from 'dashboard/i18n/locale/ru/contact.json';
import en from 'dashboard/i18n/locale/en/contact.json';
import kk from 'dashboard/i18n/locale/kk/contact.json';

const block = locale => locale.CONTACTS_LAYOUT.SIDEBAR.SHARED_PHONE;
const USED_KEYS = [
  'NO_OWN_CHATS',
  'ROUTE_VIA_CHAT',
  'ROUTE_VIA_CHAT_NO_PHONE',
  'ROUTE_BOOKING_NOTE',
  'ROUTE_OWN_NUMBER',
  'ROUTE_UNROUTABLE',
  'OPEN_CHAT',
  'HINT_RELEASED',
  'HINT_RELEASED_NO_OWNER',
  'HINT_MEDELEMENT',
  'HINT_SIBLINGS',
  'HINT_PROMOTE',
  'HINT_DISMISS',
  'DIALOG_TITLE',
  'DIALOG_NUMBER',
  'DIALOG_MOVES',
  'DIALOG_NOTHING_MOVES',
  'DIALOG_CHAT',
  'DIALOG_STAYS',
  'DIALOG_NOT_MOVED',
  'DIALOG_AUDIT',
  'DIALOG_CONFIRM',
  'STATE_CHANGED',
  'TAKEN',
  'PROMOTED',
  'FAILED',
  'PROMOTION_DISABLED',
];

describe('shared phone translations', () => {
  it('defines every key in ru, en and kk', () => {
    [ru, en, kk].forEach(locale => {
      expect(Object.keys(block(locale)).sort()).toEqual([...USED_KEYS].sort());
    });
  });

  it('has real Kazakh and Russian texts, not English fallbacks', () => {
    USED_KEYS.forEach(key => {
      expect(block(kk)[key]).not.toEqual(block(en)[key]);
      expect(block(ru)[key]).not.toEqual(block(en)[key]);
    });
  });

  it('keeps the same placeholders in every language', () => {
    const placeholders = text => (text.match(/\{[a-z]+\}/g) || []).sort();
    USED_KEYS.forEach(key => {
      expect(placeholders(block(kk)[key])).toEqual(
        placeholders(block(en)[key])
      );
      expect(placeholders(block(ru)[key])).toEqual(
        placeholders(block(en)[key])
      );
    });
  });
});
