import { nextTick } from 'vue';
import { mount } from '@vue/test-utils';
import WhatsAppTemplateParser from './WhatsAppTemplateParser.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => `${key} ${params?.share ?? ''}`,
  }),
}));

describe('WhatsAppTemplateParser appointment fields', () => {
  it('shows the missing-value share below the mapped variable', async () => {
    const wrapper = mount(WhatsAppTemplateParser, {
      props: {
        template: {
          name: 'visit_confirmation',
          language: 'ru',
          category: 'UTILITY',
          components: [{ type: 'BODY', text: 'Visit {{1}}' }],
        },
        initialProcessedParams: {
          body: { 1: '[Service](field://appointment.service_name)' },
        },
        appointmentFieldStats: [
          { field_id: 'appointment.service_name', share: 0.38, blocking: true },
        ],
      },
      global: {
        stubs: { TemplateParamInput: true, TemplatePreview: true },
      },
    });
    await nextTick();

    expect(wrapper.text()).toContain(
      'SCHEDULING.REMINDERS.ERRORS.FIELD_EMPTY_WARNING 38'
    );
  });
});
