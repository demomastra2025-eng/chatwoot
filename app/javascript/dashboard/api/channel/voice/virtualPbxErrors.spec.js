import ruLocale from 'dashboard/i18n/locale/ru/inboxMgmt.json';
import enLocale from 'dashboard/i18n/locale/en/inboxMgmt.json';
import kkLocale from 'dashboard/i18n/locale/kk/inboxMgmt.json';
import {
  virtualPbxErrorText,
  virtualPbxErrorsText,
  virtualPbxRequestErrorText,
} from './virtualPbxErrors';

const lookup = (messages, key) =>
  key.split('.').reduce((node, part) => node?.[part], messages);

const buildI18n = messages => ({
  te: key => typeof lookup(messages, key) === 'string',
  t: (key, params = {}) =>
    lookup(messages, key).replace(/\{(\w+)\}/g, (_, name) => params[name]),
});

const ru = buildI18n(ruLocale);
const errorKeys = locale =>
  Object.keys(locale.INBOX_MGMT.ADD.VOICE.VIRTUAL_PBX.ERRORS).sort();

describe('virtualPbxErrors', () => {
  it('names the channel of the same account that already holds the number', () => {
    expect(
      virtualPbxErrorText(
        {
          code: 'number_ref_taken',
          message: 'Generated number_ref is already used by another channel',
          conflict: { inbox_id: 5248, inbox_name: 'Sip', same_account: true },
        },
        ru
      )
    ).toBe(
      'Этот номер уже подключён к каналу звонков «Sip» (#5248). Откройте этот канал или удалите его, чтобы подключить номер заново.'
    );
  });

  it('shows only the channel id when the number belongs to another account', () => {
    expect(
      virtualPbxErrorText(
        {
          code: 'display_phone_number_taken',
          conflict: { inbox_id: 5248, same_account: false },
        },
        ru
      )
    ).toBe(
      'Этот номер уже подключён к каналу звонков #5248 в другом аккаунте OneLink.'
    );
  });

  it('explains a number conflict without channel details', () => {
    expect(virtualPbxErrorText({ code: 'number_ref_taken' }, ru)).toBe(
      'Этот номер уже подключён к другому каналу звонков.'
    );
  });

  it('merges the same number conflict reported by both checks', () => {
    const conflict = { inbox_id: 7, inbox_name: 'Sip', same_account: true };

    expect(
      virtualPbxErrorsText(
        [
          { code: 'number_ref_taken', conflict },
          { code: 'display_phone_number_taken', conflict },
          { code: 'connection_host_required' },
        ],
        ru
      )
    ).toBe(
      'Этот номер уже подключён к каналу звонков «Sip» (#7). Откройте этот канал или удалите его, чтобы подключить номер заново. Укажите адрес SIP-сервера.'
    );
  });

  it('localizes Beeline validation codes', () => {
    expect(
      virtualPbxErrorText(
        {
          code: 'beeline_sip_domain_required',
          message: 'connection.sip_domain is required for Beeline Cloud PBX',
        },
        ru
      )
    ).toBe('Укажите SIP-домен Билайн (vpbx-company-XXXX.cloudpbx.beeline.kz).');
    expect(virtualPbxErrorText({ code: 'beeline_codec_invalid' }, ru)).toBe(
      'Облачной АТС Билайн нужен кодек G.711 A-law (PCMA).'
    );
  });

  it('points employee errors at the form row', () => {
    expect(
      virtualPbxErrorText(
        {
          code: 'profile_user_not_in_inbox',
          message:
            'profiles[1].user_id must be an inbox collaborator before SIP assignment',
        },
        ru
      )
    ).toBe(
      'Сотрудник 2: Сначала добавьте сотрудника в участники канала, затем назначьте SIP-доступ.'
    );
  });

  it('falls back to the API message for an unknown code', () => {
    expect(
      virtualPbxErrorText(
        { code: 'future_code', message: 'Something new happened' },
        ru
      )
    ).toBe('Something new happened');
  });

  it('localizes request-level API errors', () => {
    expect(
      virtualPbxRequestErrorText(
        {
          response: {
            status: 409,
            data: {
              code: 'VIRTUAL_PBX_CONFIGURATION_STALE',
              error:
                'Virtual PBX configuration changed; reload it before saving',
            },
          },
        },
        ru,
        'fallback'
      )
    ).toBe(
      'Настройки канала изменились в другом месте. Обновите страницу и сохраните снова.'
    );
  });

  it('shows the API validation text instead of a generic failure', () => {
    expect(
      virtualPbxRequestErrorText(
        {
          message: 'Request failed with status code 422',
          response: {
            status: 422,
            data: {
              code: 'VALIDATION_ERROR',
              error: 'Номер телефона уже существует',
            },
          },
        },
        ru,
        'Не удалось создать канал звонков'
      )
    ).toBe('Номер телефона уже существует');
  });

  it('maps provisioning errors returned inside a failed response body', () => {
    expect(
      virtualPbxRequestErrorText(
        {
          response: {
            status: 422,
            data: {
              payload: { errors: [{ code: 'ingress_number_required' }] },
            },
          },
        },
        ru,
        'fallback'
      )
    ).toBe('Укажите технический номер, на который провайдер присылает звонки.');
  });

  it('uses the fallback when the request never reached the API', () => {
    expect(
      virtualPbxRequestErrorText(
        new Error('Network Error'),
        ru,
        'Не удалось создать канал звонков'
      )
    ).toBe('Не удалось создать канал звонков');
  });

  it('keeps the same error codes in every dashboard language', () => {
    expect(errorKeys(enLocale)).toEqual(errorKeys(ruLocale));
    expect(errorKeys(kkLocale)).toEqual(errorKeys(ruLocale));
  });
});
