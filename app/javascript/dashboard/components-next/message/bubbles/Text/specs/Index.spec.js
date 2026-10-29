import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ref } from 'vue';
import { mount } from '@vue/test-utils';
import TextBubble from '../Index.vue';

const mockContext = {
  content: ref('Здравствуйте, Асет!\nВрач: Иванов И.И.'),
  attachments: ref([]),
  contentAttributes: ref({}),
  messageType: ref(1),
  additionalAttributes: ref({}),
  templateButtons: ref([]),
  variant: ref('bot'),
  orientation: ref('right'),
  inReplyTo: ref(null),
  shouldGroupWithNext: ref(false),
};

vi.mock('../../../provider.js', () => ({
  useMessageContext: () => mockContext,
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/useTranslations', () => ({
  useTranslations: () => ({
    hasTranslations: ref(false),
    translationContent: ref(''),
  }),
}));

const mountBubble = () =>
  mount(TextBubble, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        BaseBubble: { template: '<div><slot /></div>' },
        FormattedContent: {
          props: ['content'],
          template: '<div class="formatted">{{ content }}</div>',
        },
        AttachmentChips: true,
        CaptainToolExecutionGroup: true,
        TranslationToggle: true,
      },
    },
  });

describe('TextBubble WhatsApp template buttons and Flows cards', () => {
  beforeEach(() => {
    mockContext.content.value = 'Здравствуйте, Асет!\nВрач: Иванов И.И.';
    mockContext.attachments.value = [];
    mockContext.contentAttributes.value = {};
    mockContext.additionalAttributes.value = {};
    mockContext.templateButtons.value = [];
  });

  it('renders WhatsApp template buttons below the message content', () => {
    mockContext.additionalAttributes.value = {
      templateButtons: [
        { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
        { type: 'URL', text: 'Открыть 2ГИС' },
      ],
    };
    mockContext.templateButtons.value = [
      { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
      { type: 'URL', text: 'Открыть 2ГИС' },
    ];

    const wrapper = mountBubble();

    const buttonsContainer = wrapper.find(
      '[data-testid="whatsapp-template-buttons"]'
    );
    expect(buttonsContainer.exists()).toBe(true);

    const buttons = wrapper.findAll('[data-testid="whatsapp-template-button"]');
    expect(buttons).toHaveLength(2);
    expect(buttons[0].text()).toBe('Растаймын | Подтверждаю');
    expect(buttons[0].find('.i-lucide-corner-up-left').exists()).toBe(true);
    expect(buttons[1].text()).toBe('Открыть 2ГИС');
    expect(buttons[1].find('.i-lucide-external-link').exists()).toBe(true);
  });

  it('renders outgoing WhatsApp Flow CTA footer', () => {
    mockContext.content.value = 'Выберите удобное время записи.';
    mockContext.contentAttributes.value = {
      whatsappPayload: {
        type: 'flow',
        flow: {
          flowId: 'flow_booking_1',
          flowCta: 'Записаться',
        },
      },
    };

    const wrapper = mountBubble();
    const cta = wrapper.find('[data-testid="whatsapp-flow-cta"]');
    expect(cta.exists()).toBe(true);
    expect(cta.text()).toBe('Записаться');
    expect(cta.find('.i-lucide-workflow').exists()).toBe(true);
  });

  it('renders incoming WhatsApp Flow booked status card and filters internal response keys', () => {
    mockContext.content.value = 'Онлайн-запись: УЗИ • Д-р Ахметов';
    mockContext.contentAttributes.value = {
      whatsappFlowBooking: {
        status: 'booked',
        serviceName: 'УЗИ',
        resourceName: 'Д-р Ахметов',
        slotLabel: '30.10.2026 10:00–10:30',
      },
      whatsappFlowResponse: {
        response: {
          flow_token: 'olf1.secret.sig',
          onelink_flow_kind: 'booking',
          resource_id: '7',
          service_id: '3',
          service_name: 'УЗИ',
          resource_name: 'Д-р Ахметов',
          slot_label: '30.10.2026 10:00–10:30',
          client_first_name: 'Марат',
          client_phone: '+77015550101',
          notes: 'Натощак',
        },
      },
    };

    const wrapper = mountBubble();
    const bookingCard = wrapper.find('[data-testid="whatsapp-flow-booking"]');
    expect(bookingCard.exists()).toBe(true);
    expect(bookingCard.text()).toContain(
      'CONVERSATION.WHATSAPP_FLOWS.BOOKING_CONFIRMED'
    );
    expect(
      wrapper.find('[data-testid="whatsapp-flow-booking-summary"]').text()
    ).toBe('УЗИ • Д-р Ахметов • 30.10.2026 10:00–10:30');

    const rows = wrapper.findAll('[data-testid="whatsapp-flow-response-row"]');
    expect(rows).toHaveLength(3);
    const responseText = wrapper
      .find('[data-testid="whatsapp-flow-response"]')
      .text();
    expect(responseText).toContain('Марат');
    expect(responseText).toContain('+77015550101');
    expect(responseText).toContain('Натощак');
    expect(responseText).not.toContain('olf1.secret.sig');
  });

  it('renders incoming WhatsApp Flow failed booking card with error details', () => {
    mockContext.content.value = 'Sent';
    mockContext.contentAttributes.value = {
      whatsapp_flow_booking: {
        status: 'failed',
        service_name: 'УЗИ',
        error_message: 'Выбранное время занято',
      },
    };

    const wrapper = mountBubble();
    const bookingCard = wrapper.find('[data-testid="whatsapp-flow-booking"]');
    expect(bookingCard.exists()).toBe(true);
    expect(bookingCard.text()).toContain(
      'CONVERSATION.WHATSAPP_FLOWS.BOOKING_FAILED'
    );
    expect(
      wrapper.find('[data-testid="whatsapp-flow-booking-error"]').text()
    ).toBe('Выбранное время занято');
  });
});
