import { describe, expect, it } from 'vitest';

import enConversation from '../locale/en/conversation.json';
import ruConversation from '../locale/ru/conversation.json';
import kkConversation from '../locale/kk/conversation.json';
import enTemplates from '../locale/en/whatsappTemplates.json';
import ruTemplates from '../locale/ru/whatsappTemplates.json';
import kkTemplates from '../locale/kk/whatsappTemplates.json';

// The texts of a WhatsApp conversation whose 24-hour window is closed. They
// are the way out of a dead end, so none of the three languages may lack one.
const texts = locale => {
  const { FOOTER } = locale.conversation.CONVERSATION;
  const { PICKER } = locale.templates.WHATSAPP_TEMPLATES;
  return {
    templateButton: FOOTER.TEMPLATE_BUTTON,
    templateOnly: FOOTER.WHATSAPP_TEMPLATE_ONLY,
    noApproved: PICKER.NO_APPROVED_TEMPLATES,
    inReview: PICKER.TEMPLATES_IN_REVIEW,
    openSettings: PICKER.OPEN_TEMPLATES_SETTINGS,
  };
};

const LOCALES = {
  en: { conversation: enConversation, templates: enTemplates },
  ru: { conversation: ruConversation, templates: ruTemplates },
  kk: { conversation: kkConversation, templates: kkTemplates },
};

describe('closed WhatsApp window texts', () => {
  it('has every text in English, Russian and Kazakh', () => {
    Object.values(LOCALES).forEach(locale => {
      Object.values(texts(locale)).forEach(text => {
        expect(typeof text).toBe('string');
        expect(text.trim()).not.toBe('');
      });
    });
  });

  it('uses the agreed Russian wording', () => {
    const ru = texts(LOCALES.ru);

    expect(ru.templateButton).toBe('Шаблон');
    expect(ru.templateOnly).toBe(
      'Клиент не писал последние 24 часа — WhatsApp разрешает начать только шаблоном.'
    );
    expect(ru.noApproved).toBe('Нет одобренных шаблонов.');
    expect(ru.inReview).toBe('Шаблоны на проверке у WhatsApp: {count}.');
    expect(ru.openSettings).toBe('Шаблоны WhatsApp');
  });

  it('uses the agreed Kazakh wording', () => {
    const kk = texts(LOCALES.kk);

    expect(kk.templateButton).toBe('Шаблон');
    expect(kk.templateOnly).toBe(
      'Клиент соңғы 24 сағатта жазбаған — WhatsApp тек шаблонмен бастауға рұқсат береді.'
    );
    expect(kk.noApproved).toBe('Мақұлданған шаблон жоқ.');
    expect(kk.inReview).toBe('WhatsApp тексерісіндегі шаблондар: {count}.');
  });

  it('keeps the review count placeholder in every language', () => {
    Object.values(LOCALES).forEach(locale => {
      expect(texts(locale).inReview).toContain('{count}');
    });
  });
});
