import { describe, expect, it } from 'vitest';

import enInbox from 'dashboard/i18n/locale/en/inboxMgmt.json';
import ruInbox from 'dashboard/i18n/locale/ru/inboxMgmt.json';
import kkInbox from 'dashboard/i18n/locale/kk/inboxMgmt.json';
import enTemplates from 'dashboard/i18n/locale/en/whatsappTemplates.json';
import kkTemplates from 'dashboard/i18n/locale/kk/whatsappTemplates.json';
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

describe('one wording for the state of a channel', () => {
  it('calls a working channel «Подключён» in the header, the list and the badges', () => {
    const wording = pick(ruInbox, 'INBOX_MGMT.EDIT.CONNECTION_STATUS.CONNECTED');

    expect(wording).toBe('Подключён');
    expect(pick(ruInbox, 'INBOX_MGMT.HEALTH_STATUS.CONNECTED')).toBe(wording);
    expect(pick(ruInbox, 'INBOX_MGMT.LIST.STATUS.CONNECTED')).toBe(wording);
  });

  it('says a voice channel is ready for calls', () => {
    expect(
      pick(ruInbox, 'INBOX_MGMT.HEALTH_STATUS.CONNECTED_VOICE_DESCRIPTION')
    ).toBe('Канал готов принимать звонки.');
    expect(
      pick(ruInbox, 'INBOX_MGMT.HEALTH_STATUS.CONNECTED_DESCRIPTION')
    ).toBe('Канал готов принимать сообщения.');
  });

  it('writes «Подключён» and «Отключён» with «ё» in the technical states too', () => {
    expect(
      pick(ruInbox, 'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.STATE_LABELS.CONNECTED')
    ).toBe('Подключён');
    expect(
      pick(
        ruInbox,
        'INBOX_MGMT.EDIT.TELEGRAM_PERSONAL.STATE_LABELS.DISCONNECTED'
      )
    ).toBe('Отключён');
  });

  it('says «канал», not «inbox», when asking for the Telegram login code', () => {
    const hint = pick(
      ruInbox,
      'INBOX_MGMT.FINISH.TELEGRAM_PERSONAL.REQUEST_CODE_HINT'
    );

    expect(hint).toContain('канал');
    expect(hint).not.toMatch(/inbox/i);
  });
});

describe('WhatsApp Web developer block texts', () => {
  const captions = [
    'INSTANCE',
    'SERVICE_USER',
    'CONNECTION',
    'STATUS',
    'LAST_SYNCED',
    'MISSING_PROVIDER_MESSAGE_ID',
    'MISSING_PROVIDER_CONVERSATION_ID',
    'PROVISIONAL_CONTACTS',
  ];

  it('names the missing ids in Russian', () => {
    expect(
      pick(ruInbox, 'INBOX_MGMT.EDIT.WHATSAPP_WEB.MISSING_PROVIDER_MESSAGE_ID')
    ).toBe('Нет ID сообщения у провайдера');
    expect(
      pick(
        ruInbox,
        'INBOX_MGMT.EDIT.WHATSAPP_WEB.MISSING_PROVIDER_CONVERSATION_ID'
      )
    ).toBe('Нет ID диалога у провайдера');
  });

  it.each([
    ['ru', ruInbox],
    ['en', enInbox],
    ['kk', kkInbox],
  ])('writes every caption of the grid without a colon in %s', (_, tree) => {
    captions.forEach(key => {
      const text = pick(tree, `INBOX_MGMT.EDIT.WHATSAPP_WEB.${key}`);

      if (text !== undefined) {
        expect(text, key).not.toMatch(/:\s*$/);
      }
    });
  });

  it.each([
    ['ru', ruInbox],
    ['en', enInbox],
    ['kk', kkInbox],
  ])('writes the captions of the WeChat grid without a colon in %s', (_, tree) => {
    ['PROVIDER_ACCOUNT_ID', 'STATUS', 'CONNECTION', 'LAST_SYNCED'].forEach(
      key => {
        expect(
          pick(tree, `INBOX_MGMT.EDIT.WEIXIN.${key}`),
          key
        ).not.toMatch(/:\s*$/);
      }
    );
  });
});

describe('WhatsApp template rejection reasons', () => {
  const reasons = [
    'ABUSIVE_CONTENT',
    'INCORRECT_CATEGORY',
    'INVALID_FORMAT',
    'SCAM',
    'TAG_CONTENT_MISMATCH',
    'PROMOTIONAL',
    'OTHER',
  ];

  it.each([
    ['ru', ruTemplates],
    ['en', enTemplates],
    ['kk', kkTemplates],
  ])('has a text for every reason in %s, including the generic one', (_, tree) => {
    reasons.forEach(reason => {
      expect(
        pick(tree, `WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS.${reason}`),
        reason
      ).toEqual(expect.any(String));
    });
  });

  it('explains the promotional reason and the generic one in Russian', () => {
    expect(
      pick(ruTemplates, 'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS.OTHER')
    ).toBe('Другая причина');
    expect(
      hasCyrillic(
        pick(
          ruTemplates,
          'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS.PROMOTIONAL'
        )
      )
    ).toBe(true);
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
