import { mount } from '@vue/test-utils';

import TemplatePreview from './TemplatePreview.vue';
import { PLATFORMS } from 'dashboard/services/TemplateConstants';

const dompurifyHtml = (el, binding) => {
  el.innerHTML = binding.value || '';
};

const mountPreview = props =>
  mount(TemplatePreview, {
    props,
    global: {
      directives: {
        'dompurify-html': dompurifyHtml,
      },
      stubs: {
        Button: {
          props: ['label'],
          template: '<button>{{ label }}</button>',
        },
        Icon: true,
        FileIcon: true,
      },
    },
  });

describe('TemplatePreview', () => {
  it('renders WhatsApp text header, body, footer, and buttons with variables', () => {
    const wrapper = mountPreview({
      platform: PLATFORMS.WHATSAPP,
      variables: { name: 'Aida', 1: '42' },
      template: {
        name: 'order_update',
        language: 'en',
        components: [
          { type: 'HEADER', format: 'TEXT', text: 'Hi {{name}}' },
          { type: 'BODY', text: 'Order {{1}} is ready' },
          { type: 'FOOTER', text: 'OneLink' },
          {
            type: 'BUTTONS',
            buttons: [{ type: 'URL', text: 'View order' }],
          },
        ],
      },
    });

    expect(wrapper.text()).toContain('Hi Aida');
    expect(wrapper.text()).toContain('Order 42 is ready');
    expect(wrapper.text()).toContain('OneLink');
    expect(wrapper.text()).toContain('View order');
  });

  it('uses entered media URL for WhatsApp media previews before template examples', () => {
    const wrapper = mountPreview({
      platform: PLATFORMS.WHATSAPP,
      variables: { media_url: 'https://cdn.example.com/current.jpg' },
      template: {
        name: 'media_update',
        language: 'en',
        components: [
          {
            type: 'HEADER',
            format: 'IMAGE',
            example: { header_handle: ['https://cdn.example.com/example.jpg'] },
          },
          { type: 'BODY', text: 'Preview image' },
        ],
      },
    });

    expect(wrapper.find('img').attributes('src')).toBe(
      'https://cdn.example.com/current.jpg'
    );
  });
});
