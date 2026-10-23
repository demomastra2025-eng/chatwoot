import { describe, expect, it } from 'vitest';

import ru from 'dashboard/i18n/locale/ru/inboxMgmt.json';
import en from 'dashboard/i18n/locale/en/inboxMgmt.json';
import kk from 'dashboard/i18n/locale/kk/inboxMgmt.json';
import {
  describeWhatsappTokenExpiry,
  getWhatsappTokenExpiry,
} from './whatsappTokenExpiry';

const NOW = new Date('2026-10-23T09:00:00Z');

const inboxWith = tokenHealth => ({
  provider_config: { token_health: tokenHealth },
});

const translator =
  messages =>
  (key, params = {}) => {
    const value = key.split('.').reduce((node, part) => node?.[part], messages);
    return typeof value === 'string'
      ? value.replace(/\{(\w+)\}/g, (_match, name) => params[name] ?? '')
      : key;
  };

describe('getWhatsappTokenExpiry', () => {
  it('is empty unless the server marks the token as expiring', () => {
    expect(getWhatsappTokenExpiry(null, NOW)).toBeNull();
    expect(getWhatsappTokenExpiry({}, NOW)).toBeNull();
    expect(
      getWhatsappTokenExpiry(inboxWith({ status: 'healthy' }), NOW)
    ).toBeNull();
    expect(
      getWhatsappTokenExpiry(inboxWith({ status: 'invalid' }), NOW)
    ).toBeNull();
  });

  it('counts the days left from the expiry date', () => {
    const expiry = getWhatsappTokenExpiry(
      inboxWith({
        status: 'expiring',
        expires_at: '2026-11-01T12:00:00Z',
        expires_in_days: 12,
      }),
      NOW
    );

    expect(expiry.daysLeft).toBe(9);
    expect(expiry.expiresAt.toISOString()).toBe('2026-11-01T12:00:00.000Z');
  });

  it('uses the days from the server when the date is missing or broken', () => {
    expect(
      getWhatsappTokenExpiry(
        inboxWith({ status: 'expiring', expires_in_days: 4 }),
        NOW
      )
    ).toEqual({ expiresAt: null, daysLeft: 4 });
    expect(
      getWhatsappTokenExpiry(
        inboxWith({
          status: 'expiring',
          expires_at: 'not a date',
          expires_in_days: 3,
        }),
        NOW
      )
    ).toEqual({ expiresAt: null, daysLeft: 3 });
  });

  it('does not invent a number of days', () => {
    expect(
      getWhatsappTokenExpiry(inboxWith({ status: 'expiring' }), NOW)
    ).toEqual({ expiresAt: null, daysLeft: null });
    expect(
      getWhatsappTokenExpiry(
        inboxWith({ status: 'expiring', expires_in_days: null }),
        NOW
      ).daysLeft
    ).toBeNull();
  });

  it('never goes below zero days', () => {
    expect(
      getWhatsappTokenExpiry(
        inboxWith({ status: 'expiring', expires_at: '2026-10-20T00:00:00Z' }),
        NOW
      ).daysLeft
    ).toBe(0);
  });
});

describe('describeWhatsappTokenExpiry', () => {
  const expiry = getWhatsappTokenExpiry(
    inboxWith({
      status: 'expiring',
      expires_at: '2026-11-01T12:00:00Z',
      expires_in_days: 9,
    }),
    NOW
  );

  it('says when the authorization ends, with the date and the days left', () => {
    expect(
      describeWhatsappTokenExpiry(expiry, {
        t: translator(ru),
        locale: 'ru',
        now: NOW,
      })
    ).toBe(
      'Авторизация WhatsApp истекает через 9 дн. (1 ноября). Переподключите заранее.'
    );
  });

  it('formats the date in the language of the interface', () => {
    const textFor = (messages, locale) =>
      describeWhatsappTokenExpiry(expiry, {
        t: translator(messages),
        locale,
        now: NOW,
      });

    expect(textFor(en, 'en')).toBe(
      'WhatsApp authorization expires in 9 day(s) (November 1). Reconnect in advance.'
    );
    expect(textFor(kk, 'kk')).toContain('9 күннен кейін');
    expect(textFor(kk, 'kk')).not.toContain('November');
  });

  it('adds the year when the date is in another year', () => {
    const nextYear = getWhatsappTokenExpiry(
      inboxWith({ status: 'expiring', expires_at: '2027-01-05T12:00:00Z' }),
      NOW
    );

    expect(
      describeWhatsappTokenExpiry(nextYear, {
        t: translator(ru),
        locale: 'ru',
        now: NOW,
      })
    ).toContain('2027');
  });

  it('says "today" on the last day', () => {
    const today = getWhatsappTokenExpiry(
      inboxWith({ status: 'expiring', expires_at: '2026-10-23T20:00:00Z' }),
      NOW
    );

    expect(
      describeWhatsappTokenExpiry(today, {
        t: translator(ru),
        locale: 'ru',
        now: NOW,
      })
    ).toBe('Авторизация WhatsApp истекает сегодня. Переподключите сейчас.');
  });

  it('leaves the date out when the server did not send it', () => {
    expect(
      describeWhatsappTokenExpiry(
        { expiresAt: null, daysLeft: 4 },
        { t: translator(ru), locale: 'ru', now: NOW }
      )
    ).toBe('Авторизация WhatsApp истекает через 4 дн. Переподключите заранее.');
  });

  it('is empty when there is nothing to say', () => {
    const options = { t: translator(ru), locale: 'ru', now: NOW };

    expect(describeWhatsappTokenExpiry(null, options)).toBe('');
    expect(
      describeWhatsappTokenExpiry({ expiresAt: null, daysLeft: null }, options)
    ).toBe('');
  });

  it('has the texts in Russian, English and Kazakh', () => {
    [ru, en, kk].forEach(messages => {
      [
        'TOKEN_EXPIRING_IN_DAYS',
        'TOKEN_EXPIRING_IN_DAYS_NO_DATE',
        'TOKEN_EXPIRING_TODAY',
        'CONNECTED_VOICE_DESCRIPTION',
      ].forEach(key =>
        expect(messages.INBOX_MGMT.HEALTH_STATUS[key], key).toEqual(
          expect.any(String)
        )
      );
    });
  });
});
