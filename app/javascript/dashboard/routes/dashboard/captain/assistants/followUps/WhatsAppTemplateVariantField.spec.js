import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

vi.mock(
  'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue',
  () => ({
    default: defineComponent({
      name: 'WhatsAppTemplateParserStub',
      setup(_props, { expose }) {
        expose({
          processedParams: ref({ body: { 1: 'Асет' } }),
          isFormInvalid: ref(false),
        });
        return () => h('div', { 'data-testid': 'template-parser' });
      },
    }),
  })
);

const { default: WhatsAppTemplateVariantField } = await import(
  './WhatsAppTemplateVariantField.vue'
);

const templates = [
  {
    name: 'follow_up_ru',
    namespace: 'business',
    category: 'UTILITY',
    language: 'ru',
    components: [{ type: 'BODY', text: 'Здравствуйте, {{1}}' }],
  },
  {
    name: 'follow_up_en',
    namespace: 'business',
    category: 'UTILITY',
    language: 'en_US',
    components: [{ type: 'BODY', text: 'Hello' }],
  },
];

describe('WhatsAppTemplateVariantField', () => {
  it('shows only templates for the configured language', () => {
    const wrapper = mount(WhatsAppTemplateVariantField, {
      props: { language: 'ru', templates },
    });

    const options = wrapper.findAll('option').map(option => option.text());
    expect(options).toContain('follow_up_ru');
    expect(options).not.toContain('follow_up_en');
  });

  it('emits complete transport params from the approved template parser', async () => {
    const wrapper = mount(WhatsAppTemplateVariantField, {
      props: { language: 'ru', templates },
    });

    await wrapper.get('select').setValue('follow_up_ru');
    const selectedParams = wrapper.emitted('update:modelValue').at(-1)[0];
    await wrapper.setProps({ modelValue: selectedParams });
    await flushPromises();

    expect(wrapper.emitted('update:modelValue')).toEqual(
      expect.arrayContaining([
        [
          expect.objectContaining({
            name: 'follow_up_ru',
            namespace: 'business',
            category: 'UTILITY',
            language: 'ru',
          }),
        ],
      ])
    );
    expect(wrapper.get('[data-testid="template-parser"]').exists()).toBe(true);
  });
});
