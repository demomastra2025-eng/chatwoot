import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import Fallback from './Fallback.vue';

const messageContext = {
  attachments: ref([
    {
      dataUrl: 'https://www.example.com/shared-link',
      fallbackTitle: 'Shared link',
    },
  ]),
  content: ref('Caption text'),
};

vi.mock('../provider.js', () => ({
  useMessageContext: () => messageContext,
}));

const createWrapper = () =>
  shallowMount(Fallback, {
    global: {
      stubs: {
        BaseBubble: {
          template: '<div data-test-id="fallback-bubble"><slot /></div>',
        },
        FormattedContent: {
          props: ['content'],
          template: '<div data-test-id="formatted-content">{{ content }}</div>',
        },
      },
    },
  });

describe('Fallback', () => {
  beforeEach(() => {
    messageContext.attachments.value = [
      {
        dataUrl: 'https://www.example.com/shared-link',
        fallbackTitle: 'Shared link',
      },
    ];
    messageContext.content.value = 'Caption text';
  });

  it('renders fallback attachments as clickable links with optional message content', () => {
    const wrapper = createWrapper();
    const link = wrapper.find('a');

    expect(wrapper.find('[data-test-id="formatted-content"]').text()).toBe(
      'Caption text'
    );
    expect(link.attributes('href')).toBe('https://www.example.com/shared-link');
    expect(link.text()).toBe('Shared link');
  });

  it('supports snake_case attachment payloads from API responses', () => {
    messageContext.attachments.value = [
      {
        data_url: 'https://www.example.com/snake-case-link',
        fallback_title: 'Snake case link',
      },
    ];
    messageContext.content.value = '';

    const wrapper = createWrapper();
    const link = wrapper.find('a');

    expect(link.attributes('href')).toBe(
      'https://www.example.com/snake-case-link'
    );
    expect(link.text()).toBe('Snake case link');
  });
});
