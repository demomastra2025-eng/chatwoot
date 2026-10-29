import { describe, it, expect } from 'vitest';
import {
  resolveWhatsappTemplateButtons,
  whatsappTemplateButtonIcon,
} from '../whatsappTemplateButtons';

describe('whatsappTemplateButtons', () => {
  it('returns persisted templateButtons from camelCased additionalAttributes', () => {
    const buttons = resolveWhatsappTemplateButtons({
      additionalAttributes: {
        templateButtons: [
          { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
          { type: 'URL', text: 'Открыть карту' },
        ],
      },
    });

    expect(buttons).toEqual([
      { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
      { type: 'URL', text: 'Открыть карту' },
    ]);
  });

  it('falls back to inbox.message_templates using templateParams name and language', () => {
    const buttons = resolveWhatsappTemplateButtons({
      additionalAttributes: {
        templateParams: {
          name: 'dostarmed_visit_reminder_bilingual_v2',
          language: 'ru_RU',
        },
      },
      inbox: {
        message_templates: [
          {
            name: 'dostarmed_visit_reminder_bilingual_v2',
            language: 'ru',
            components: [
              { type: 'BODY', text: 'Напоминание' },
              {
                type: 'BUTTONS',
                buttons: [
                  { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
                  { type: 'PHONE_NUMBER', text: 'Позвонить в клинику' },
                ],
              },
            ],
          },
        ],
      },
    });

    expect(buttons).toEqual([
      { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
      { type: 'PHONE_NUMBER', text: 'Позвонить в клинику' },
    ]);
  });

  it('maps WhatsApp button types to icons', () => {
    expect(whatsappTemplateButtonIcon('QUICK_REPLY')).toBe(
      'i-lucide-corner-up-left'
    );
    expect(whatsappTemplateButtonIcon('URL')).toBe('i-lucide-external-link');
    expect(whatsappTemplateButtonIcon('PHONE_NUMBER')).toBe('i-lucide-phone');
    expect(whatsappTemplateButtonIcon('COPY_CODE')).toBe('i-lucide-copy');
  });
});
