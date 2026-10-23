import { describe, expect, it } from 'vitest';

import enInbox from 'dashboard/i18n/locale/en/inboxMgmt.json';
import ruInbox from 'dashboard/i18n/locale/ru/inboxMgmt.json';
import enTemplates from 'dashboard/i18n/locale/en/whatsappTemplates.json';
import ruTemplates from 'dashboard/i18n/locale/ru/whatsappTemplates.json';

const pick = (tree, path) =>
  path.split('.').reduce((node, part) => node?.[part], tree);

const hasCyrillic = text => /[А-Яа-яЁё]/.test(text);

const leafPaths = (node, prefix) =>
  Object.entries(node).flatMap(([key, value]) =>
    typeof value === 'object' && value !== null
      ? leafPaths(value, `${prefix}.${key}`)
      : [`${prefix}.${key}`]
  );

describe('channel settings texts in Russian', () => {
  it('translates the whole webhook block of the WhatsApp account health tab', () => {
    const paths = leafPaths(
      pick(ruInbox, 'INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK'),
      'INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK'
    );

    expect(paths.length).toBeGreaterThan(5);
    paths.forEach(path => expect(hasCyrillic(pick(ruInbox, path))).toBe(true));
  });

  it('has Russian labels for health values, recovery states and connection status', () => {
    [
      'INBOX_MGMT.ACCOUNT_HEALTH.VALUES.QUALITY',
      'INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.STATES',
      'INBOX_MGMT.EDIT.CONNECTION_STATUS',
      'INBOX_MGMT.EDIT.DEVELOPER_DETAILS',
      'INBOX_MGMT.EDIT.VOICE_CALLS',
      'INBOX_MGMT.PRE_CHAT_FORM.FIELD_NAMES',
      'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES',
    ].forEach(branch => {
      leafPaths(pick(ruInbox, branch), branch).forEach(path => {
        const text = pick(ruInbox, path);
        // «Email» is the same word in Russian.
        expect(text === 'Email' || hasCyrillic(text), path).toBe(true);
      });
    });
  });

  it('names the connection states and the new blocks the way the owner asked', () => {
    expect(pick(ruInbox, 'INBOX_MGMT.EDIT.CONNECTION_STATUS')).toEqual({
      CONNECTED: 'Подключён',
      CONNECTING: 'Подключается…',
      DISCONNECTED: 'Нет связи',
    });
    expect(pick(ruInbox, 'INBOX_MGMT.EDIT.DEVELOPER_DETAILS.TITLE')).toBe(
      'Для разработчика'
    );
    expect(pick(ruInbox, 'INBOX_MGMT.TABS.VOICE_CALLS')).toBe(
      'Звонки и сотрудники'
    );
  });

  it('translates every WhatsApp template category and status', () => {
    ['UTILITY', 'MARKETING', 'AUTHENTICATION'].forEach(category =>
      expect(
        hasCyrillic(
          pick(
            ruTemplates,
            `WHATSAPP_TEMPLATES.MANAGEMENT.CATEGORY_OPTIONS.${category}`
          )
        )
      ).toBe(true)
    );
    [
      'APPROVED',
      'PENDING',
      'IN_APPEAL',
      'REJECTED',
      'PAUSED',
      'DISABLED',
      'FLAGGED',
      'LIMIT_EXCEEDED',
      'PENDING_DELETION',
      'DELETED',
      'ARCHIVED',
    ].forEach(status =>
      expect(
        hasCyrillic(
          pick(ruTemplates, `WHATSAPP_TEMPLATES.MANAGEMENT.STATUSES.${status}`)
        ),
        status
      ).toBe(true)
    );
  });

  it('uses «Сохранить» on the settings save buttons', () => {
    [
      'INBOX_MGMT.SETTINGS_POPUP.UPDATE',
      'INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_SECTION_UPDATE_BUTTON',
      'INBOX_MGMT.SETTINGS_POPUP.UPDATE_PRE_CHAT_FORM_SETTINGS',
      'INBOX_MGMT.IMAP.UPDATE',
      'INBOX_MGMT.SMTP.UPDATE',
    ].forEach(path => {
      expect(pick(ruInbox, path), path).toMatch(/^Сохранить/);
    });
  });

  it('does not show the raw «Ключ» column title of the pre-chat form', () => {
    expect(
      pick(ruInbox, 'INBOX_MGMT.PRE_CHAT_FORM.SET_FIELDS_HEADER.KEY')
    ).not.toBe('Ключ');
  });
});

describe('channel settings texts in English', () => {
  it('has every new key that Russian has', () => {
    [
      [ruInbox, enInbox, 'INBOX_MGMT.EDIT.CONNECTION_STATUS'],
      [ruInbox, enInbox, 'INBOX_MGMT.EDIT.DEVELOPER_DETAILS'],
      [ruInbox, enInbox, 'INBOX_MGMT.EDIT.VOICE_CALLS'],
      [ruInbox, enInbox, 'INBOX_MGMT.TABS.VOICE_CALLS'],
      [ruInbox, enInbox, 'INBOX_MGMT.ACCOUNT_HEALTH.VALUES'],
      [ruInbox, enInbox, 'INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.STATES'],
      [ruInbox, enInbox, 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_NAMES'],
      [ruInbox, enInbox, 'INBOX_MGMT.PRE_CHAT_FORM.FIELD_TYPES'],
      [ruTemplates, enTemplates, 'WHATSAPP_TEMPLATES.MANAGEMENT.STATUSES'],
      [
        ruTemplates,
        enTemplates,
        'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS',
      ],
    ].forEach(([ru, en, branch]) => {
      const node = pick(ru, branch);
      const paths =
        typeof node === 'object' ? leafPaths(node, branch) : [branch];

      paths.forEach(path => expect(typeof pick(en, path), path).toBe('string'));
    });
  });
});
