import { describe, expect, it } from 'vitest';

import en from '../locale/en/inboxMgmt.json';
import kk from '../locale/kk/inboxMgmt.json';
import ru from '../locale/ru/inboxMgmt.json';

const locales = { en, kk, ru };

const getPath = (object, path) =>
  path.split('.').reduce((value, key) => value?.[key], object);

describe('Weixin inbox management translations', () => {
  it.each(Object.entries(locales))(
    'defines all Weixin inbox creation keys for %s',
    (_, messages) => {
      [
        'INBOX_MGMT.ADD.AUTH.CHANNEL.WEIXIN.TITLE',
        'INBOX_MGMT.ADD.AUTH.CHANNEL.WEIXIN.DESCRIPTION',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.TITLE',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.DESC',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.LABEL',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.PLACEHOLDER',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.DISPLAY_NAME.SUBTITLE',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.SUBMIT_BUTTON',
        'INBOX_MGMT.ADD.WEIXIN_CHANNEL.API.ERROR_MESSAGE',
        'INBOX_MGMT.FINISH.WEIXIN.TITLE',
        'INBOX_MGMT.FINISH.WEIXIN.DESCRIPTION',
        'INBOX_MGMT.FINISH.WEIXIN.REQUEST_QR',
        'INBOX_MGMT.FINISH.WEIXIN.REFRESH_QR',
        'INBOX_MGMT.FINISH.WEIXIN.QR_READY',
        'INBOX_MGMT.FINISH.WEIXIN.CONNECTED_SUCCESS',
        'INBOX_MGMT.FINISH.WEIXIN.CONNECTED_REDIRECT',
        'INBOX_MGMT.EDIT.WEIXIN.TITLE',
        'INBOX_MGMT.EDIT.WEIXIN.SERVICE_CONTROLS',
        'INBOX_MGMT.EDIT.WEIXIN.REQUEST_QR',
        'INBOX_MGMT.EDIT.WEIXIN.RECONNECT',
        'INBOX_MGMT.EDIT.WEIXIN.DISCONNECT',
        'INBOX_MGMT.EDIT.WEIXIN.DIAGNOSTICS_SECTION',
        'INBOX_MGMT.EDIT.WEIXIN.STATE_LABELS.QR_READY',
      ].forEach(path => {
        expect(getPath(messages, path), path).toEqual(expect.any(String));
        expect(getPath(messages, path), path).not.toEqual('');
      });
    }
  );
});
