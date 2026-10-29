import { describe, it, expect, vi } from 'vitest';
import { ref } from 'vue';
import { mount } from '@vue/test-utils';
import TextBubble from '../Index.vue';

const mockContext = {
  content: ref('Здравствуйте, Асет!\nВрач: Иванов И.И.'),
  attachments: ref([]),
  contentAttributes: ref({}),
  messageType: ref(1),
  additionalAttributes: ref({
    templateButtons: [
      { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
      { type: 'URL', text: 'Открыть 2ГИС' },
    ],
  }),
  templateButtons: ref([
    { type: 'QUICK_REPLY', text: 'Растаймын | Подтверждаю' },
    { type: 'URL', text: 'Открыть 2ГИС' },
  ]),
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

describe('TextBubble WhatsApp template buttons', () => {
  it('renders WhatsApp template buttons below the message content', () => {
    const wrapper = mount(TextBubble, {
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
});
