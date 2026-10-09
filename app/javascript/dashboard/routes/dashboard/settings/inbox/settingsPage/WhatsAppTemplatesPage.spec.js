import { flushPromises, shallowMount } from '@vue/test-utils';

import Switch from 'dashboard/components-next/switch/Switch.vue';
import WhatsAppTemplatesPage from './WhatsAppTemplatesPage.vue';

const { dispatch, useAlertMock } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlertMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
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
});
