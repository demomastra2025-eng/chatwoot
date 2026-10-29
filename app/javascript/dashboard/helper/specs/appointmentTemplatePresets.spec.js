import {
  APPOINTMENT_REMINDER_PRESETS,
  APPOINTMENT_SEMANTIC_VARIABLES,
  WHATSAPP_SUPPORTED_CLIENT_LANGUAGES,
  buildAppointmentTemplatePackDrafts,
  buildPresetMarker,
  extractPresetKeyFromRule,
  formatClientLanguageSummary,
  normalizeClientLanguageCode,
  normalizeClientLanguagesList,
  resolveClientLanguageBreakdown,
  serializeSemanticTemplateText,
  validateUtilityTemplateDraft,
} from '../appointmentTemplatePresets';
import {
  buildWhatsAppTemplatePayload,
  createEmptyWhatsAppTemplateForm,
  extractSequentialTemplateVariables,
  hasDanglingTemplateVariable,
} from '../whatsappTemplateLibrary';

describe('appointmentTemplatePresets', () => {
  it('leaves service out of every default binding and generated template', () => {
    expect(
      APPOINTMENT_REMINDER_PRESETS.every(
        preset => !preset.defaultVariableOrder.includes('service_name')
      )
    ).toBe(true);
    const drafts = buildAppointmentTemplatePackDrafts({ languageMode: 'ru' });
    expect(drafts.every(draft => !draft.bodyText.includes('{{услуга}}'))).toBe(
      true
    );
  });

  describe('#serializeSemanticTemplateText', () => {
    it('converts universal semantic variables into sequential Meta placeholders with examples and field:// bindings', () => {
      const result = serializeSemanticTemplateText(
        'Здравствуйте, {{имя клиента}}! Дата: {{дата записи}}, время: {{время записи}}. Специалист: {{специалист}}. Услуга: {{услуга}}.'
      );

      expect(result.error).toBe('');
      expect(result.serializedText).toBe(
        'Здравствуйте, {{1}}! Дата: {{2}}, время: {{3}}. Специалист: {{4}}. Услуга: {{5}}.'
      );
      expect(result.variables).toEqual(['1', '2', '3', '4', '5']);
      expect(result.examples).toEqual({
        1: 'Анна',
        2: '25.08.2026',
        3: '15:30',
        4: 'Алия Серикова',
        5: 'Консультация',
      });
      expect(result.bindings).toEqual({
        1: '[Имя клиента](field://appointment.client_name)',
        2: '[Дата записи](field://appointment.start_date)',
        3: '[Время записи](field://appointment.start_time)',
        4: '[Специалист](field://appointment.resource_name)',
        5: '[Услуга](field://appointment.service_name_snapshot)',
      });
    });

    it('reuses the same positional index when a semantic variable appears twice (e.g. KK + RU bilingual body)', () => {
      const result = serializeSemanticTemplateText(
        'Сәлеметсіз бе, {{имя клиента}}! Уақыты: {{время записи}}.\n\n—————————\n\nЗдравствуйте, {{имя клиента}}! Время: {{время записи}}.'
      );

      expect(result.error).toBe('');
      expect(result.serializedText).toBe(
        'Сәлеметсіз бе, {{1}}! Уақыты: {{2}}.\n\n—————————\n\nЗдравствуйте, {{1}}! Время: {{2}}.'
      );
      expect(result.variables).toEqual(['1', '2']);
    });
  });

  describe('#validateUtilityTemplateDraft', () => {
    it('rejects Kazakh case endings attached via hyphen to variables, promotional stop-words, and adjacent variables', () => {
      const caseSuffixResult = validateUtilityTemplateDraft({
        name: 'booking_reminder_1d',
        language: 'kk',
        bodyText:
          'Сәлеметсіз бе, {{имя клиента}}! Сіз сағат {{время записи}}-ке жазылдыңыз.',
      });
      expect(caseSuffixResult.valid).toBe(false);
      expect(caseSuffixResult.errors.map(e => e.code)).toContain(
        'variable_case_suffix'
      );

      const promoResult = validateUtilityTemplateDraft({
        name: 'booking_created_notice',
        language: 'ru',
        bodyText:
          'Здравствуйте, {{имя клиента}}! На ваш приём действует скидка 20%.',
      });
      expect(promoResult.valid).toBe(false);
      expect(promoResult.errors.map(e => e.code)).toContain(
        'promotional_content'
      );

      const validKkResult = validateUtilityTemplateDraft({
        name: 'booking_reminder_1d',
        language: 'kk',
        bodyText:
          'Сәлеметсіз бе, {{имя клиента}}! Күні: {{дата записи}}, сағат {{время записи}} уақытында күтеміз.',
      });
      expect(validKkResult.valid).toBe(true);
    });

    it('normalizes supported WhatsApp client languages', () => {
      expect(WHATSAPP_SUPPORTED_CLIENT_LANGUAGES.length).toBeGreaterThan(20);
      expect(normalizeClientLanguageCode('kz')).toBe('kk');
      expect(normalizeClientLanguageCode('en_US')).toBe('en');
      expect(normalizeClientLanguagesList(['kz', 'ru', 'en'])).toEqual([
        'kk',
        'ru',
        'en',
      ]);
    });
  });

  describe('integration with whatsappTemplateLibrary', () => {
    it('recognizes semantic variables in extractSequentialTemplateVariables and buildWhatsAppTemplatePayload', () => {
      const extracted = extractSequentialTemplateVariables(
        'Здравствуйте, {{имя клиента}}! Ждём вас {{дата записи}} в {{время записи}}.'
      );
      expect(extracted.error).toBe('');
      expect(extracted.variables).toEqual(['1', '2', '3']);
      expect(extracted.examples).toEqual({
        1: 'Анна',
        2: '25.08.2026',
        3: '15:30',
      });

      const form = createEmptyWhatsAppTemplateForm();
      form.name = 'booking_created_notice';
      form.language = 'ru';
      form.bodyText =
        'Здравствуйте, {{имя клиента}}! Ждём вас {{дата записи}} в {{время записи}}.';

      const payload = buildWhatsAppTemplatePayload(form);
      expect(payload.body_text).toBe(
        'Здравствуйте, {{1}}! Ждём вас {{2}} в {{3}}.'
      );
      expect(payload.body_examples).toEqual({
        1: 'Анна',
        2: '25.08.2026',
        3: '15:30',
      });
    });

    it('detects leading or trailing semantic variables in hasDanglingTemplateVariable', () => {
      expect(
        hasDanglingTemplateVariable(
          '{{имя клиента}}, ваша запись подтверждена.'
        )
      ).toBe(true);
      expect(hasDanglingTemplateVariable('Здравствуйте, {{имя клиента}}')).toBe(
        true
      );
      expect(
        hasDanglingTemplateVariable('Здравствуйте, {{имя клиента}}!')
      ).toBe(false);
    });
  });

  describe('#buildAppointmentTemplatePackDrafts', () => {
    it('builds all 6 universal appointment templates in bilingual KK+RU mode with confirmation quick-reply button', () => {
      const drafts = buildAppointmentTemplatePackDrafts({
        languageMode: 'both',
        includeCompany: true,
        companyNameRu: 'Prime Studio',
        companyNameKk: 'Prime Studio',
        greetByName: true,
        includeDateTime: true,
        includeSpecialist: true,
        includeService: true,
        confirmationDayBefore: true,
        includeLocationUrl: true,
        locationUrl: 'https://2gis.kz/almaty/firm/123',
      });

      expect(drafts).toHaveLength(APPOINTMENT_REMINDER_PRESETS.length);

      const createdDraft = drafts.find(
        item => item.presetKey === 'appointment_created'
      );
      expect(createdDraft.name).toBe('booking_created_notice');
      expect(createdDraft.bodyText).toContain('—————————');
      expect(createdDraft.bodyText).toContain('Prime Studio');
      expect(createdDraft.serializedBodyText).not.toContain('{{имя клиента}}');
      expect(createdDraft.serializedBodyText).toContain('{{1}}');
      expect(createdDraft.buttons).toEqual([
        {
          type: 'URL',
          text: 'Как добраться',
          url: 'https://2gis.kz/almaty/firm/123',
          example: '',
          phoneNumber: '',
        },
      ]);

      const dayBeforeDraft = drafts.find(
        item => item.presetKey === 'appointment_day_before'
      );
      expect(dayBeforeDraft.buttons).toEqual([
        {
          type: 'QUICK_REPLY',
          text: 'Подтверждаю запись',
          url: '',
          example: '',
          phoneNumber: '',
        },
      ]);
    });

    it('uses universal terminology across all semantic variables', () => {
      const labels = APPOINTMENT_SEMANTIC_VARIABLES.map(
        item => item.defaultLabel
      );
      expect(labels).toEqual([
        'Имя клиента',
        'Дата записи',
        'Время записи',
        'Специалист',
        'Услуга',
        'Телефон клиента',
      ]);
    });
  });

  describe('preset rule markers', () => {
    it('round-trips preset markers in automation rule descriptions', () => {
      const marker = buildPresetMarker('appointment_day_before');
      expect(
        extractPresetKeyFromRule({
          description: `Automated reminder ${marker}`,
        })
      ).toBe('appointment_day_before');
    });

    it('ensures all 6 default bilingual drafts pass validateUtilityTemplateDraft', () => {
      const drafts = buildAppointmentTemplatePackDrafts({
        languageMode: 'both',
        includeCompany: true,
        companyNameRu: 'Клиника Улыбка',
        companyNameKk: 'Улыбка клиникасы',
      });
      expect(drafts).toHaveLength(6);
      drafts.forEach(draft => {
        const validation = validateUtilityTemplateDraft({
          name: draft.name,
          bodyText: draft.bodyText,
          language: draft.language,
          category: 'UTILITY',
          buttons: draft.buttons,
          bilingual: true,
        });
        expect(validation.valid).toBe(true);
      });
    });
  });

  describe('client language percentage breakdown formatting', () => {
    it('formats multi-language breakdown compactly in Russian', () => {
      const attrs = {
        client_language: 'ru',
        client_language_breakdown: [
          { code: 'ru', percentage: 70 },
          { code: 'kk', percentage: 30 },
        ],
      };

      expect(resolveClientLanguageBreakdown(attrs)).toEqual([
        { code: 'ru', label: 'Русский', percentage: 70 },
        { code: 'kk', label: 'Казахский', percentage: 30 },
      ]);
      expect(formatClientLanguageSummary(attrs)).toBe(
        'Русский 70% · Казахский 30%'
      );
    });

    it('derives percentages summing to 100% from legacy counts or single language', () => {
      expect(
        formatClientLanguageSummary({
          client_language_counts: { kk: 3, ru: 1 },
        })
      ).toBe('Казахский 75% · Русский 25%');

      expect(
        formatClientLanguageSummary({
          client_language: 'kk',
        })
      ).toBe('Казахский 100%');

      expect(formatClientLanguageSummary({})).toBe('');
    });
  });
});
