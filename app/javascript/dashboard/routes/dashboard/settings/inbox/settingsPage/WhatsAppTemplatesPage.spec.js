import { flushPromises, shallowMount } from '@vue/test-utils';

import Switch from 'dashboard/components-next/switch/Switch.vue';
import WhatsAppTemplatesPage from './WhatsAppTemplatesPage.vue';

const { dispatch, useAlertMock, translations, uiLocale } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlertMock: vi.fn(),
  translations: {},
  uiLocale: { value: 'ru' },
}));

// Unknown keys come back as the key itself, like vue-i18n does.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      (translations[key] ?? key).replace(
        /\{(\w+)\}/g,
        (_match, name) => params[name] ?? ''
      ),
    locale: uiLocale,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: useAlertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

const template = (name, extra = {}) => ({
  name,
  language: 'en_US',
  status: 'APPROVED',
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
  ...extra,
});

const inbox = {
  id: 7,
  csat_config: {},
  message_templates: [
    template('agent_reply'),
    template('automation_only', { visible_in_conversation_picker: false }),
  ],
};

const mountComponent = (inboxProp = inbox) =>
  shallowMount(WhatsAppTemplatesPage, {
    props: { inbox: inboxProp, embedded: true },
    global: {
      stubs: {
        Button: true,
        CreateWhatsAppTemplateDialog: true,
        Dialog: true,
        Input: true,
      },
    },
  });

const switchFor = (wrapper, templateName) => {
  const card = wrapper
    .findAll('[data-test="whatsapp-template-card"]')
    .find(node => node.text().includes(templateName));
  return card.findComponent(Switch);
};

describe('WhatsAppTemplatesPage', () => {
  beforeEach(() => {
    dispatch.mockReset();
    useAlertMock.mockReset();
    uiLocale.value = 'ru';
  });

  it('shows whether each template is offered in conversations', () => {
    const wrapper = mountComponent();

    expect(switchFor(wrapper, 'agent_reply').props('modelValue')).toBe(true);
    expect(switchFor(wrapper, 'automation_only').props('modelValue')).toBe(
      false
    );
  });

  it('keeps compact copy and exposes every language variant', () => {
    const wrapper = mountComponent({
      id: 7,
      csat_config: { template: { name: 'support_survey' } },
      message_templates: [
        template('support_survey', {
          components: [
            { type: 'HEADER', format: 'TEXT', text: 'How did we do?' },
            {
              type: 'BODY',
              text: 'Thanks for contacting support. Please rate the service.',
            },
            { type: 'FOOTER', text: 'Thank you' },
            {
              type: 'BUTTONS',
              buttons: [{ type: 'QUICK_REPLY', text: 'Rate now' }],
            },
          ],
        }),
        template('support_survey', {
          language: 'es_ES',
          status: 'PENDING',
          components: [
            { type: 'BODY', text: 'Gracias por contactar con soporte.' },
          ],
        }),
      ],
    });
    const card = wrapper.find('[data-test="whatsapp-template-card"]');
    const details = card.find('[data-test="full-template-details"]');

    expect(
      card.find('[data-test="template-body-preview"]').classes()
    ).toContain('line-clamp-2');
    expect(card.findAll('[data-test="template-variant"]')).toHaveLength(2);
    expect(card.text()).toContain('WHATSAPP_TEMPLATES.MANAGEMENT.CSAT_BADGE');
    expect(details.element.tagName).toBe('DETAILS');
    expect(
      details.findAll('[data-test="template-variant-details"]')
    ).toHaveLength(2);
    expect(details.text()).toContain('How did we do?');
    expect(details.text()).toContain(
      'Thanks for contacting support. Please rate the service.'
    );
    expect(details.text()).toContain('Thank you');
    expect(details.text()).toContain('Rate now');
    expect(details.text()).toContain('Gracias por contactar con soporte.');
  });

  it('shows native carousel components and keeps flat draft cards available', () => {
    const wrapper = mountComponent({
      id: 7,
      csat_config: {},
      message_templates: [
        template('native_carousel', {
          category: 'MARKETING',
          components: [
            { type: 'BODY', text: 'Browse these products.' },
            {
              type: 'CAROUSEL',
              cards: [
                {
                  components: [
                    { type: 'HEADER', format: 'IMAGE' },
                    { type: 'BODY', text: 'First product card.' },
                    {
                      type: 'BUTTONS',
                      buttons: [
                        {
                          type: 'URL',
                          text: 'View first product',
                          url: 'https://example.test/first',
                        },
                      ],
                    },
                  ],
                },
                {
                  components: [
                    { type: 'HEADER', format: 'VIDEO' },
                    { type: 'BODY', text: 'Second product card.' },
                    {
                      type: 'BUTTONS',
                      buttons: [{ type: 'QUICK_REPLY', text: 'Ask about it' }],
                    },
                  ],
                },
              ],
            },
          ],
        }),
        template('flat_carousel_draft', {
          category: 'MARKETING',
          carousel_cards: [
            {
              header_type: 'image',
              body_text: 'Flat draft card body.',
              buttons: [{ type: 'QUICK_REPLY', text: 'Draft button' }],
            },
          ],
        }),
      ],
    });
    const templateCards = wrapper.findAll(
      '[data-test="whatsapp-template-card"]'
    );
    const nativeTemplateCard = templateCards.find(card =>
      card.text().includes('native_carousel')
    );
    const nativeDetails = nativeTemplateCard.find(
      '[data-test="full-template-details"]'
    );
    const nativeCarouselCards = nativeDetails.findAll(
      '[data-test="template-carousel-card"]'
    );
    const flatTemplateCard = templateCards.find(card =>
      card.text().includes('flat_carousel_draft')
    );
    const flatDetails = flatTemplateCard.find(
      '[data-test="full-template-details"]'
    );

    expect(nativeCarouselCards).toHaveLength(2);
    expect(nativeCarouselCards[0].text()).toContain('IMAGE');
    expect(nativeCarouselCards[0].text()).toContain('First product card.');
    expect(nativeCarouselCards[0].text()).toContain('View first product');
    expect(nativeCarouselCards[0].text()).toContain(
      'https://example.test/first'
    );
    expect(nativeCarouselCards[1].text()).toContain('VIDEO');
    expect(nativeCarouselCards[1].text()).toContain('Second product card.');
    expect(nativeCarouselCards[1].text()).toContain('Ask about it');
    expect(flatDetails.text()).toContain('image');
    expect(flatDetails.text()).toContain('Flat draft card body.');
    expect(flatDetails.text()).toContain('Draft button');
  });

  it('shows the category and the status of every language in Russian', () => {
    Object.assign(translations, {
      'WHATSAPP_TEMPLATES.MANAGEMENT.CATEGORY_OPTIONS.MARKETING': 'Маркетинг',
      'WHATSAPP_TEMPLATES.MANAGEMENT.CATEGORY_OPTIONS.AUTHENTICATION':
        'Код подтверждения',
      'WHATSAPP_TEMPLATES.MANAGEMENT.STATUSES.APPROVED': 'Одобрен',
      'WHATSAPP_TEMPLATES.MANAGEMENT.STATUSES.PENDING': 'На проверке',
      'WHATSAPP_TEMPLATES.MANAGEMENT.STATUSES.PAUSED': 'Приостановлен',
      'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS.INVALID_FORMAT':
        'Неверный формат шаблона',
    });
    const wrapper = mountComponent({
      id: 7,
      csat_config: {},
      message_templates: [
        template('promo', { category: 'MARKETING', status: 'PAUSED' }),
        template('promo', { language: 'ru', status: 'PENDING' }),
        template('login_code', { category: 'AUTHENTICATION' }),
        template('broken', {
          status: 'REJECTED',
          rejected_reason: 'INVALID_FORMAT',
        }),
      ],
    });
    const card = name =>
      wrapper
        .findAll('[data-test="whatsapp-template-card"]')
        .find(node => node.text().includes(name));

    expect(card('promo').text()).toContain('Маркетинг');
    expect(card('promo').text()).toContain('Приостановлен');
    expect(card('promo').text()).toContain('На проверке');
    expect(card('login_code').text()).toContain('Код подтверждения');
    expect(card('login_code').text()).toContain('Одобрен');
    expect(card('broken').text()).toContain('Неверный формат шаблона');

    [
      'UTILITY',
      'MARKETING',
      'AUTHENTICATION',
      'APPROVED',
      'PENDING',
      'PAUSED',
    ].forEach(code => expect(wrapper.text()).not.toContain(code));
  });

  it('falls back to a readable word for a status without a translation', () => {
    const wrapper = mountComponent({
      id: 7,
      csat_config: {},
      message_templates: [
        template('odd', { status: 'LIMIT_EXCEEDED', category: 'SERVICE' }),
      ],
    });
    const text = wrapper.find('[data-test="whatsapp-template-card"]').text();

    expect(text).toContain('Limit exceeded');
    expect(text).toContain('Service');
    expect(text).not.toContain('LIMIT_EXCEEDED');
  });

  it('hides a template from the conversation picker', async () => {
    dispatch.mockResolvedValue({});
    const wrapper = mountComponent();

    switchFor(wrapper, 'agent_reply').vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'inboxes/updateWhatsAppTemplateVisibility',
      { inboxId: 7, templateName: 'agent_reply', visible: false }
    );
  });

  it('disables the switch while the change is saving', async () => {
    let resolveUpdate;
    dispatch.mockReturnValue(
      new Promise(resolve => {
        resolveUpdate = resolve;
      })
    );
    const wrapper = mountComponent();

    switchFor(wrapper, 'automation_only').vm.$emit('update:modelValue', true);
    await wrapper.vm.$nextTick();

    expect(switchFor(wrapper, 'automation_only').props('disabled')).toBe(true);
    expect(switchFor(wrapper, 'agent_reply').props('disabled')).toBe(false);

    resolveUpdate({});
    await flushPromises();

    expect(switchFor(wrapper, 'automation_only').props('disabled')).toBe(false);
  });

  it('shows the API error when the change fails', async () => {
    dispatch.mockRejectedValue(new Error('WhatsApp template not found'));
    const wrapper = mountComponent();

    switchFor(wrapper, 'agent_reply').vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(useAlertMock).toHaveBeenCalledWith('WhatsApp template not found');
    expect(switchFor(wrapper, 'agent_reply').props('modelValue')).toBe(true);
  });

  describe('rejection reasons', () => {
    const rejectedCard = reason => {
      const wrapper = mountComponent({
        id: 7,
        csat_config: {},
        message_templates: [
          template('refused', { status: 'REJECTED', rejected_reason: reason }),
        ],
      });
      return wrapper.find('[data-test="whatsapp-template-card"]');
    };

    beforeEach(() => {
      Object.assign(translations, {
        'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS.PROMOTIONAL':
          'Рекламный текст не подходит для этой категории',
        'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASONS.OTHER':
          'Другая причина',
      });
    });

    it('translates the promotional reason', () => {
      const text = rejectedCard('PROMOTIONAL').text();

      expect(text).toContain('Рекламный текст не подходит для этой категории');
      expect(text).not.toContain('PROMOTIONAL');
    });

    it.each(['SOMETHING_NEW_FROM_META', 'ZZZ'])(
      'shows «Другая причина» instead of the raw %s',
      reason => {
        const text = rejectedCard(reason).text();

        expect(text).toContain('Другая причина');
        expect(text).not.toContain(reason);
      }
    );

    it('shows nothing for a template that was not rejected', () => {
      const text = rejectedCard('NONE').text();

      expect(text).not.toContain('Другая причина');
      expect(text).not.toContain('NONE');
    });
  });

  describe('languages', () => {
    const variantsText = wrapper =>
      wrapper
        .findAll('[data-test="template-variant"]')
        .map(node => node.text());

    it('names the languages instead of showing codes', () => {
      const wrapper = mountComponent({
        id: 7,
        csat_config: {},
        message_templates: [
          template('promo', { language: 'ru' }),
          template('promo', { language: 'en' }),
        ],
      });
      const chips = variantsText(wrapper);

      expect(chips[0]).toContain('Русский');
      expect(chips[1]).toContain('Английский');
      chips.forEach(chip => expect(chip).not.toMatch(/\b(ru|en)\b/));
    });

    it('follows the interface language', () => {
      uiLocale.value = 'en';
      const wrapper = mountComponent({
        id: 7,
        csat_config: {},
        message_templates: [template('promo', { language: 'ru' })],
      });

      expect(variantsText(wrapper)[0]).toContain('Russian');
    });

    it('keeps the code of a language it does not know', () => {
      const wrapper = mountComponent({
        id: 7,
        csat_config: {},
        message_templates: [template('promo', { language: 'xx' })],
      });

      expect(variantsText(wrapper)[0]).toContain('xx');
    });

    it('names the language in the full view and in the rejection title', () => {
      Object.assign(translations, {
        'WHATSAPP_TEMPLATES.MANAGEMENT.REJECTION_REASON':
          'Причина отклонения для языка {language}',
      });
      const wrapper = mountComponent({
        id: 7,
        csat_config: {},
        message_templates: [
          template('refused', {
            language: 'ru',
            status: 'REJECTED',
            rejected_reason: 'SCAM',
          }),
        ],
      });
      const details = wrapper.find('[data-test="full-template-details"]');

      expect(details.text()).toContain('Русский');
      expect(details.text()).toContain('Причина отклонения для языка Русский');
    });
  });

  describe('toolbar', () => {
    const toolbarFor = (inbox = {}) =>
      mountComponent({
        id: 7,
        csat_config: {},
        message_templates: [template('agent_reply')],
        ...inbox,
      }).find('[data-test="whatsapp-templates-toolbar"]');

    beforeEach(() => {
      Object.assign(translations, {
        'WHATSAPP_TEMPLATES.MANAGEMENT.LAST_SYNC':
          'Последняя синхронизация: {timestamp}',
      });
    });

    it('formats the last sync date in the interface language, not the browser one', () => {
      const date = '2026-10-23T09:17:00Z';
      const expected = locale =>
        new Intl.DateTimeFormat(locale, {
          dateStyle: 'medium',
          timeStyle: 'short',
        }).format(new Date(date));

      expect(
        toolbarFor({ message_templates_last_updated: date }).text()
      ).toContain(expected('ru'));

      uiLocale.value = 'en';
      expect(
        toolbarFor({ message_templates_last_updated: date }).text()
      ).toContain(expected('en'));
      expect(expected('ru')).not.toBe(expected('en'));
    });

    it('shows the whole last sync label and the whole search box', () => {
      const toolbar = toolbarFor({
        message_templates_last_updated: '2026-10-23T09:17:00Z',
      });
      const label = toolbar
        .findAll('span')
        .find(node => node.text().startsWith('Последняя синхронизация'));

      expect(label.exists()).toBe(true);
      // A hidden or truncated label shows «…» instead of the date.
      expect(label.classes()).not.toContain('truncate');
      expect(label.classes()).not.toContain('hidden');
      expect(toolbar.find('input, input-stub').exists()).toBe(true);
      expect(toolbar.find('.shrink-0').classes()).toContain('max-w-md');
    });
  });
});
