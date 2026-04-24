import { describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { shallowMount } from '@vue/test-utils';

import EmailBubble from './Index.vue';

vi.mock('../../provider.js', () => ({
  useMessageContext: () => ({
    content: ref('Plain text fallback'),
    contentAttributes: ref({
      email: {
        htmlContent: {
          full: '<div><img src="logo.png" style="vertical-align: middle" />Signature text</div>',
        },
        textContent: {
          full: 'Signature text',
        },
      },
    }),
    attachments: ref([]),
    messageType: ref(1),
    sender: ref({ type: 'User' }),
    senderType: ref('User'),
  }),
}));

vi.mock('dashboard/composables/useTranslations', () => ({
  useTranslations: () => ({
    hasTranslations: ref(false),
    translationContent: ref(''),
  }),
}));

vi.mock('dashboard/helper/emailQuoteExtractor.js', () => ({
  EmailQuoteExtractor: {
    extractQuotes: html => html,
    hasQuotes: () => false,
  },
}));

const letterStub = {
  name: 'Letter',
  props: ['allowedCssProperties', 'html', 'text', 'className'],
  template: '<div />',
};

const mountComponent = () =>
  shallowMount(EmailBubble, {
    global: {
      stubs: {
        BaseBubble: { template: '<div><slot /></div>' },
        EmailMeta: true,
        Icon: true,
        FormattedContent: true,
        AttachmentChips: true,
        TranslationToggle: true,
        Letter: letterStub,
      },
      mocks: {
        $t: key => key,
      },
    },
  });

describe('EmailBubble', () => {
  it('uses a signature-safe letter render class for logo/text alignment fallback', () => {
    const wrapper = mountComponent();
    const letter = wrapper.findComponent(letterStub);

    expect(letter.props('className')).toContain('email-signature-layout');
  });
});
