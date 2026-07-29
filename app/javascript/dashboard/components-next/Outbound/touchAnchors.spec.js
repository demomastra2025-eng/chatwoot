import { describe, expect, it } from 'vitest';

import en from '../../i18n/locale/en/campaign.json';
import kk from '../../i18n/locale/kk/campaign.json';
import ru from '../../i18n/locale/ru/campaign.json';

const locales = { en, kk, ru };
const touchCreatedAtLabels = {
  en: 'Follow-up applied',
  kk: 'Қайта хабарласу қолданылды',
  ru: 'Применение дожима',
};

describe('touch anchor translations', () => {
  it.each(Object.entries(locales))(
    'keeps both %s touch editor anchor namespaces in sync',
    (locale, messages) => {
      const nestedAnchors =
        messages.OUTBOUND_WORKSPACE.TOUCHES.TOUCH_EDITOR.ANCHORS;
      const directAnchors = messages.OUTBOUND_WORKSPACE.TOUCH_EDITOR.ANCHORS;

      expect(directAnchors).toEqual(nestedAnchors);
      expect(directAnchors.TOUCH_CREATED_AT).toBe(touchCreatedAtLabels[locale]);
      expect(directAnchors.APPOINTMENT_CREATED_AT).toBeTruthy();
      expect(directAnchors.TASK_CREATED_AT).toBeTruthy();
      expect(directAnchors.DEAL_CREATED_AT).toBeTruthy();
      expect(
        messages.OUTBOUND_WORKSPACE.TOUCHES.TOUCH_EDITOR
          .UNSUPPORTED_CHANNEL_WARNING
      ).toBe(
        messages.OUTBOUND_WORKSPACE.TOUCH_EDITOR.UNSUPPORTED_CHANNEL_WARNING
      );
    }
  );
});
