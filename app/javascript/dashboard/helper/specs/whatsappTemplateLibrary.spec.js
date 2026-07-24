import {
  buildWhatsAppTemplatePayload,
  createEmptyWhatsAppTemplateForm,
  extractSequentialTemplateVariables,
  groupWhatsAppTemplates,
  hasDanglingTemplateVariable,
  matchesWhatsAppTemplateSearch,
  sortWhatsAppTemplates,
  TEMPLATE_BUTTON_TYPE_OPTIONS,
} from '../whatsappTemplateLibrary';

describe('whatsappTemplateLibrary', () => {
  describe('#extractSequentialTemplateVariables', () => {
    it('extracts ordered numeric variables without duplicates', () => {
      expect(
        extractSequentialTemplateVariables('Hello {{1}}, order {{2}} and {{1}}')
      ).toEqual({
        variables: ['1', '2'],
        error: '',
      });
    });

    it('returns an error for non-sequential variables', () => {
      expect(extractSequentialTemplateVariables('Hello {{1}} {{3}}')).toEqual({
        variables: [],
        error: 'Variables must be sequential without gaps',
      });
    });
  });

  describe('#buildWhatsAppTemplatePayload', () => {
    it('normalizes the template payload before submit', () => {
      const form = createEmptyWhatsAppTemplateForm();
      form.name = ' order_update ';
      form.bodyText = ' Hello {{1}} ';
      form.bodyExamples = { 1: ' Alex ', 2: ' ' };
      form.buttons = [
        {
          type: 'URL',
          text: ' Track ',
          url: ' https://example.com ',
          example: ' ',
        },
      ];

      expect(buildWhatsAppTemplatePayload(form)).toEqual({
        name: 'order_update',
        language: 'en',
        category: 'UTILITY',
        header_type: 'none',
        header_text: '',
        body_text: 'Hello {{1}}',
        footer_text: '',
        sample_media_url: '',
        body_examples: { 1: ' Alex ' },
        header_examples: {},
        buttons: [
          {
            type: 'URL',
            text: 'Track',
            url: 'https://example.com',
            example: '',
            phone_number: '',
          },
        ],
      });
    });

    it('includes copy code and phone number button fields in the payload', () => {
      const form = createEmptyWhatsAppTemplateForm();
      form.buttons = [
        {
          type: 'COPY_CODE',
          text: '',
          url: '',
          example: ' SAVE20 ',
          phoneNumber: '',
        },
        {
          type: 'PHONE_NUMBER',
          text: ' Call us ',
          url: '',
          example: '',
          phoneNumber: ' +16505551234 ',
        },
      ];

      expect(buildWhatsAppTemplatePayload(form).buttons).toEqual([
        {
          type: 'COPY_CODE',
          text: '',
          url: '',
          example: 'SAVE20',
          phone_number: '',
        },
        {
          type: 'PHONE_NUMBER',
          text: 'Call us',
          url: '',
          example: '',
          phone_number: '+16505551234',
        },
      ]);
    });

    it('builds authentication templates without custom components', () => {
      const form = createEmptyWhatsAppTemplateForm();
      form.name = ' login_code ';
      form.language = 'en_US';
      form.category = 'AUTHENTICATION';
      form.bodyText = 'This stale body must not be submitted';
      form.addSecurityRecommendation = true;
      form.codeExpirationMinutes = '15';

      expect(buildWhatsAppTemplatePayload(form)).toEqual({
        name: 'login_code',
        language: 'en_US',
        category: 'AUTHENTICATION',
        add_security_recommendation: true,
        code_expiration_minutes: 15,
      });
    });

    it('normalizes catalog buttons', () => {
      const form = createEmptyWhatsAppTemplateForm();
      form.category = 'MARKETING';
      form.buttons = [
        {
          type: 'CATALOG',
          text: ' View catalog ',
          url: '',
          example: '',
          phoneNumber: '',
        },
      ];

      expect(buildWhatsAppTemplatePayload(form).buttons).toEqual([
        {
          type: 'CATALOG',
          text: 'View catalog',
          url: '',
          example: '',
          phone_number: '',
        },
      ]);
    });

    it('does not expose or serialize unverified Flow creation fields', () => {
      expect(
        TEMPLATE_BUTTON_TYPE_OPTIONS.map(option => option.value)
      ).not.toContain('FLOW');

      const form = createEmptyWhatsAppTemplateForm();
      form.category = 'MARKETING';
      form.buttons = [
        {
          type: 'FLOW',
          text: ' Sign up ',
          url: '',
          example: '',
          phoneNumber: '',
          flowId: ' 123456789 ',
          flowJson: '',
          flowAction: 'navigate',
          navigateScreen: ' WELCOME_SCREEN ',
        },
      ];

      expect(buildWhatsAppTemplatePayload(form).buttons[0]).toEqual({
        type: 'FLOW',
        text: 'Sign up',
        url: '',
        example: '',
        phone_number: '',
      });
    });

    it('normalizes structured carousel cards without top-level components', () => {
      const form = createEmptyWhatsAppTemplateForm();
      form.category = 'MARKETING';
      form.bodyText = ' Browse products ';
      form.isCarousel = true;
      form.carouselCards = [
        {
          headerType: 'image',
          sampleMediaUrl: ' https://example.com/card.jpg ',
          bodyText: ' Product one ',
          bodyExamples: {},
          buttons: [
            {
              type: 'QUICK_REPLY',
              text: ' Choose ',
              url: '',
              example: '',
              phoneNumber: '',
            },
          ],
        },
      ];

      expect(buildWhatsAppTemplatePayload(form)).toEqual({
        name: '',
        language: 'en',
        category: 'MARKETING',
        header_type: 'none',
        header_text: '',
        body_text: 'Browse products',
        footer_text: '',
        sample_media_url: '',
        body_examples: {},
        header_examples: {},
        buttons: [],
        carousel_cards: [
          {
            header_type: 'image',
            sample_media_url: 'https://example.com/card.jpg',
            body_text: 'Product one',
            body_examples: {},
            buttons: [
              {
                type: 'QUICK_REPLY',
                text: 'Choose',
                url: '',
                example: '',
                phone_number: '',
              },
            ],
          },
        ],
      });
    });
  });

  describe('#hasDanglingTemplateVariable', () => {
    it('detects leading or trailing placeholders', () => {
      expect(hasDanglingTemplateVariable('{{1}} ready')).toBe(true);
      expect(hasDanglingTemplateVariable('Hello {{1}}')).toBe(true);
      expect(hasDanglingTemplateVariable('Hello {{1}}, order {{2}}.')).toBe(
        false
      );
    });
  });

  describe('#groupWhatsAppTemplates', () => {
    it('groups template variants by template name', () => {
      expect(
        groupWhatsAppTemplates([
          { name: 'order_update', language: 'ru', status: 'PENDING' },
          { name: 'order_update', language: 'en', status: 'APPROVED' },
          { name: 'invoice_ready', language: 'en', status: 'APPROVED' },
        ])
      ).toEqual([
        {
          name: 'invoice_ready',
          category: '',
          primaryVariant: {
            name: 'invoice_ready',
            language: 'en',
            status: 'APPROVED',
          },
          variants: [
            {
              name: 'invoice_ready',
              language: 'en',
              status: 'APPROVED',
            },
          ],
          languages: ['en'],
        },
        {
          name: 'order_update',
          category: '',
          primaryVariant: {
            name: 'order_update',
            language: 'en',
            status: 'APPROVED',
          },
          variants: [
            {
              name: 'order_update',
              language: 'en',
              status: 'APPROVED',
            },
            {
              name: 'order_update',
              language: 'ru',
              status: 'PENDING',
            },
          ],
          languages: ['en', 'ru'],
        },
      ]);
    });
  });

  describe('#matchesWhatsAppTemplateSearch', () => {
    const template = {
      name: 'order_update',
      variants: [
        {
          name: 'order_update',
          language: 'en',
          category: 'UTILITY',
          status: 'APPROVED',
          components: [{ type: 'BODY', text: 'Your order is ready' }],
        },
      ],
    };

    it('matches by name or body text', () => {
      expect(matchesWhatsAppTemplateSearch(template, 'order')).toBe(true);
      expect(matchesWhatsAppTemplateSearch(template, 'ready')).toBe(true);
      expect(matchesWhatsAppTemplateSearch(template, 'invoice')).toBe(false);
    });
  });

  describe('#sortWhatsAppTemplates', () => {
    it('sorts templates by name', () => {
      expect(
        sortWhatsAppTemplates([{ name: 'zeta' }, { name: 'alpha' }]).map(
          ({ name }) => name
        )
      ).toEqual(['alpha', 'zeta']);
    });
  });
});
