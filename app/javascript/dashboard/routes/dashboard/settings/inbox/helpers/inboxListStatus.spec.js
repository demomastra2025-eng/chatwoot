import en from 'dashboard/i18n/locale/en';
import kk from 'dashboard/i18n/locale/kk';
import ru from 'dashboard/i18n/locale/ru';
import {
  getInboxListStatus,
  INBOX_LIST_STATUS_I18N_KEYS,
} from './inboxListStatus';

const resolveKey = (messages, key) =>
  key.split('.').reduce((node, part) => node?.[part], messages);

const whatsappWeb = ({ lifecycle, connection, ...rest } = {}) => ({
  id: 1,
  name: 'Sales',
  channel_type: 'Channel::WhatsappWeb',
  phone_number: '+77001234567',
  lifecycle_state: lifecycle,
  connection_state: connection,
  additional_attributes: {
    evolution: { status: lifecycle, connection_state: connection },
  },
  ...rest,
});

const CONNECTED_LABEL = 'INBOX_MGMT.LIST.STATUS.CONNECTED';
const NO_CONNECTION_LABEL = 'INBOX_MGMT.LIST.STATUS.NO_CONNECTION';

describe('#getInboxListStatus', () => {
  it('returns nothing for a missing inbox', () => {
    expect(getInboxListStatus(null)).toBeNull();
  });

  describe('WhatsApp Web', () => {
    it('is connected only when the session is connected and open', () => {
      expect(
        getInboxListStatus(
          whatsappWeb({ lifecycle: 'connected', connection: 'open' })
        )
      ).toMatchObject({
        id: 'connected',
        tone: 'teal',
        labelKey: CONNECTED_LABEL,
        hintKey: null,
      });
    });

    it('shows "no connection" when the connection is closed, even if the lifecycle still says connected', () => {
      expect(
        getInboxListStatus(
          whatsappWeb({ lifecycle: 'connected', connection: 'close' })
        )
      ).toMatchObject({
        id: 'disconnected',
        tone: 'ruby',
        labelKey: NO_CONNECTION_LABEL,
        hintKey: 'INBOX_MGMT.LIST.HINT.RECONNECT',
      });
    });

    it('shows "no connection" for a disconnected or failed session', () => {
      ['disconnected', 'failed'].forEach(lifecycle => {
        expect(
          getInboxListStatus(whatsappWeb({ lifecycle, connection: 'close' }))
        ).toMatchObject({
          id: 'disconnected',
          tone: 'ruby',
          labelKey: NO_CONNECTION_LABEL,
        });
      });
    });

    it('shows a gentle "connecting" hint while the session is reconnecting', () => {
      [
        { lifecycle: 'connected', connection: 'connecting' },
        { lifecycle: 'reconnecting', connection: 'reconnecting' },
        { lifecycle: 'qr_scanned', connection: 'connecting' },
      ].forEach(state => {
        expect(getInboxListStatus(whatsappWeb(state))).toMatchObject({
          id: 'disconnected',
          tone: 'amber',
          labelKey: NO_CONNECTION_LABEL,
          hintKey: 'INBOX_MGMT.LIST.HINT.CONNECTING',
        });
      });
    });

    it('asks to finish the connection while waiting for the QR scan', () => {
      ['waiting_for_qr', 'qr_ready'].forEach(lifecycle => {
        expect(
          getInboxListStatus(
            whatsappWeb({ lifecycle, connection: 'connecting' })
          )
        ).toMatchObject({
          id: 'disconnected',
          tone: 'amber',
          hintKey: 'INBOX_MGMT.LIST.HINT.FINISH_LOGIN',
        });
      });
    });

    it('does not turn an open session red because of an old error text', () => {
      const status = getInboxListStatus(
        whatsappWeb({
          lifecycle: 'connected',
          connection: 'open',
          last_error: 'Request timeout while syncing',
        })
      );

      expect(status).toMatchObject({ id: 'connected', hintKey: null });
    });

    it('never exposes the raw provider error', () => {
      const status = getInboxListStatus(
        whatsappWeb({
          lifecycle: 'disconnected',
          connection: 'close',
          last_error: 'Evolution API 500: socket hang up',
        })
      );

      expect(JSON.stringify(status)).not.toContain('socket hang up');
      expect(status.hintKey).toBe('INBOX_MGMT.LIST.HINT.RECONNECT');
    });
  });

  describe('Telegram (personal)', () => {
    const telegramPersonal = state => ({
      id: 2,
      name: 'Telegram',
      channel_type: 'Channel::TelegramPersonal',
      phone_number: '+77001234567',
      ...state,
    });

    it('is connected only when both the connection and the login are connected', () => {
      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'connected',
            lifecycle_state: 'connected',
          })
        )
      ).toMatchObject({ id: 'connected', tone: 'teal' });
    });

    it('shows "no connection" when the account is disconnected', () => {
      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'disconnected',
            lifecycle_state: 'disconnected',
          })
        )
      ).toMatchObject({
        id: 'disconnected',
        tone: 'ruby',
        hintKey: 'INBOX_MGMT.LIST.HINT.RECONNECT',
      });
    });

    it('shows "no connection" when Telegram asks to log in again', () => {
      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'auth_required',
            lifecycle_state: 'connected',
          })
        )
      ).toMatchObject({ id: 'disconnected', tone: 'ruby' });
    });

    it('does not call a half-open session connected', () => {
      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'connected',
            lifecycle_state: 'disconnected',
          })
        )
      ).toMatchObject({ id: 'disconnected' });
    });

    it('treats connecting, waiting for login code and flood wait as softer problems', () => {
      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'connecting',
            lifecycle_state: 'connected',
          })
        )
      ).toMatchObject({
        id: 'disconnected',
        tone: 'amber',
        hintKey: 'INBOX_MGMT.LIST.HINT.CONNECTING',
      });

      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'disconnected',
            lifecycle_state: 'code_sent',
          })
        )
      ).toMatchObject({
        id: 'disconnected',
        tone: 'amber',
        hintKey: 'INBOX_MGMT.LIST.HINT.FINISH_LOGIN',
      });

      expect(
        getInboxListStatus(
          telegramPersonal({
            connection_state: 'flood_wait',
            lifecycle_state: 'connected',
          })
        )
      ).toMatchObject({
        id: 'disconnected',
        tone: 'amber',
        hintKey: 'INBOX_MGMT.LIST.HINT.TEMPORARY',
      });
    });
  });

  describe('WeChat', () => {
    it('follows the same session rules', () => {
      const weixin = state => ({
        id: 3,
        name: 'WeChat',
        channel_type: 'Channel::Weixin',
        ...state,
      });

      expect(
        getInboxListStatus(
          weixin({
            connection_state: 'connected',
            lifecycle_state: 'connected',
          })
        )
      ).toMatchObject({ id: 'connected' });
      expect(
        getInboxListStatus(
          weixin({
            connection_state: 'disconnected',
            lifecycle_state: 'qr_expired',
          })
        )
      ).toMatchObject({ id: 'disconnected', tone: 'ruby' });
    });
  });

  describe('other channels', () => {
    it('shows a normal channel with no problem as connected', () => {
      expect(
        getInboxListStatus({
          id: 4,
          name: 'Site',
          channel_type: 'Channel::WebWidget',
          website_url: 'https://example.com',
        })
      ).toMatchObject({
        id: 'connected',
        tone: 'teal',
        labelKey: CONNECTED_LABEL,
        hintKey: null,
      });
    });

    it('gives the registration-required state a proper label and hint instead of an empty badge', () => {
      const status = getInboxListStatus({
        id: 5,
        name: 'WhatsApp',
        channel_type: 'Channel::Whatsapp',
        reauthorization_required: true,
        provider_config: {
          phone_registration: { status: 'pin_incorrect' },
        },
      });

      expect(status).toMatchObject({
        id: 'disconnected',
        tone: 'amber',
        labelKey: NO_CONNECTION_LABEL,
        hintKey: 'INBOX_MGMT.LIST.HINT.REGISTRATION',
      });
      expect(resolveKey(ru, status.labelKey)).toBeTruthy();
      expect(resolveKey(ru, status.hintKey)).toBeTruthy();
    });

    it('gives the health state a short Russian label', () => {
      expect(ru.INBOX_MGMT.HEALTH_STATUS.PHONE_REGISTRATION_REQUIRED).toBe(
        'Завершите регистрацию WhatsApp'
      );
    });

    it('asks to reconnect when authorization is lost', () => {
      expect(
        getInboxListStatus({
          id: 6,
          name: 'Instagram',
          channel_type: 'Channel::Instagram',
          reauthorization_required: true,
        })
      ).toMatchObject({
        id: 'disconnected',
        tone: 'ruby',
        hintKey: 'INBOX_MGMT.LIST.HINT.RECONNECT',
      });
    });

    it('shows a provider outage as a temporary problem', () => {
      expect(
        getInboxListStatus({
          id: 7,
          name: 'WhatsApp',
          channel_type: 'Channel::Whatsapp',
          provider_config: { connection_state: 'provider unavailable' },
        })
      ).toMatchObject({
        id: 'disconnected',
        tone: 'amber',
        hintKey: 'INBOX_MGMT.LIST.HINT.TEMPORARY',
      });
    });

    it('keeps an expiring token connected and adds a gentle hint', () => {
      expect(
        getInboxListStatus({
          id: 8,
          name: 'WhatsApp',
          channel_type: 'Channel::Whatsapp',
          provider_config: { token_health: { status: 'expiring' } },
        })
      ).toMatchObject({
        id: 'connected',
        tone: 'teal',
        hintKey: 'INBOX_MGMT.LIST.HINT.EXPIRING',
        hintTone: 'amber',
      });
    });

    it('flags a broken channel record and a failed WhatsApp disconnect', () => {
      expect(
        getInboxListStatus({
          id: 9,
          channel_type: 'Channel::Whatsapp',
          channel_missing: true,
        })
      ).toMatchObject({
        id: 'disconnected',
        tone: 'ruby',
        hintKey: 'INBOX_MGMT.LIST.HINT.CHANNEL_MISSING',
      });

      expect(
        getInboxListStatus({
          id: 10,
          channel_type: 'Channel::Whatsapp',
          deletion_recovery: { status: 'failed' },
        })
      ).toMatchObject({
        id: 'disconnected',
        tone: 'amber',
        hintKey: 'INBOX_MGMT.LIST.HINT.DELETION_RECOVERY',
      });
    });

    it('never puts raw provider error text in the result', () => {
      const status = getInboxListStatus({
        id: 11,
        channel_type: 'Channel::Whatsapp',
        last_error: 'Meta 190: token abc expired',
      });

      expect(JSON.stringify(status)).not.toContain('Meta 190');
    });
  });

  it('only uses translation keys that exist in ru, en and kk', () => {
    INBOX_LIST_STATUS_I18N_KEYS.forEach(key => {
      [ru, en, kk].forEach(messages => {
        expect(resolveKey(messages, key), key).toEqual(expect.any(String));
      });
    });
  });
});
