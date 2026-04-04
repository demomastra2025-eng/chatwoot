import {
  buildWhatsAppTemplatePayload,
  createEmptyWhatsAppTemplateForm,
  extractSequentialTemplateVariables,
  groupWhatsAppTemplates,
  hasDanglingTemplateVariable,
  matchesWhatsAppTemplateSearch,
  sortWhatsAppTemplates,
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
