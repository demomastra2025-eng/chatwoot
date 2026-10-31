import { runInNewContext } from 'node:vm';
import en from '../../i18n/locale/en/inboxMgmt.json';
import ru from '../../i18n/locale/ru/inboxMgmt.json';
import zh from '../../i18n/locale/zh/inboxMgmt.json';

describe('generated widget settings compatibility', () => {
  it.each([
    ['en', en],
    ['ru', ru],
    ['zh', zh],
  ])(
    'keeps %s settings available to a cached legacy SDK',
    (_locale, messages) => {
      const context = { window: {} };
      const settings = { locale: 'kk', position: 'left' };
      const snippet =
        messages.INBOX_MGMT.WIDGET_BUILDER.SCRIPT_SETTINGS.replace(
          '{options}',
          JSON.stringify(settings)
        );
      runInNewContext(snippet, context);

      expect(context.window.onelinkSettings).toEqual(settings);
      expect(context.window.chatwootSettings).toBe(
        context.window.onelinkSettings
      );
    }
  );
});
