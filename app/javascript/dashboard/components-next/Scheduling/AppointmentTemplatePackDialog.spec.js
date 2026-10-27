import { describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import AppointmentTemplatePackDialog from './AppointmentTemplatePackDialog.vue';
import ruScheduling from 'dashboard/i18n/locale/ru/scheduling.json';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn().mockResolvedValue({}),
  alert: vi.fn(),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));

const DialogStub = {
  template: '<div><slot /></div>',
  methods: { open() {}, close() {} },
};

describe('AppointmentTemplatePackDialog', () => {
  it('keeps six editable previews and RU, KK, and combined language choices', async () => {
    const wrapper = mount(AppointmentTemplatePackDialog, {
      props: {
        inboxId: 3,
        existingTemplateNames: ['booking_reminder_1d'],
        defaultCompanyName: 'Клиника',
      },
      global: {
        plugins: [
          createI18n({
            legacy: false,
            locale: 'ru',
            messages: {
              ru: { ...ruScheduling, SWITCH: { TOGGLE: 'Переключить' } },
            },
          }),
        ],
        stubs: { Dialog: DialogStub },
      },
    });
    await flushPromises();
    expect(wrapper.findAll('[data-testid^="pack-tab-"]')).toHaveLength(6);
    expect(wrapper.find('[data-testid="lang-mode-ru"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="lang-mode-kk"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="lang-mode-both"]').exists()).toBe(true);
    await wrapper.find('[data-testid="lang-mode-both"]').trigger('click');
    expect(
      wrapper.find('[data-testid="pack-template-live-preview"]').text()
    ).not.toBe('');
    const body = wrapper.find(
      '[data-testid="pack-template-body-input"] textarea'
    );
    await body.setValue('Особый текст для {{имя клиента}}!');
    const phoneChip = wrapper
      .findAll('[data-testid="pack-variable-chip"]')
      .find(chip => chip.text().includes('{{телефон клиента}}'));
    await phoneChip.trigger('click');
    expect(
      wrapper.find('[data-testid="pack-template-live-preview"]').text()
    ).toContain('Анна');
    expect(
      wrapper.find('[data-testid="pack-template-live-preview"]').text()
    ).toContain('+7 701 000 00 00');
    await wrapper
      .find('[data-testid="reset-active-template-btn"]')
      .trigger('click');
    expect(body.element.value).not.toContain('Особый текст');
    await wrapper
      .find('[data-testid="pack-tab-appointment_day_before"]')
      .trigger('click');
    await wrapper
      .find('[data-testid="bump-template-name-btn"]')
      .trigger('click');
    expect(
      wrapper.find('[data-testid="pack-template-name-input"] input').element
        .value
    ).toBe('booking_reminder_1d_v2');
    wrapper.unmount();
  });
});
