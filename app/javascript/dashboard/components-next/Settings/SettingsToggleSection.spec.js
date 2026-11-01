import { mount } from '@vue/test-utils';
import SettingsToggleSection from './SettingsToggleSection.vue';

describe('SettingsToggleSection accessible switch', () => {
  it('names the real switch after its setting and preserves model updates', async () => {
    const wrapper = mount(SettingsToggleSection, {
      props: { header: 'Notify about appointments', modelValue: false },
    });

    const control = wrapper.get('[role="switch"]');
    expect(control.attributes('aria-label')).toBe('Notify about appointments');

    await control.trigger('click');
    expect(wrapper.emitted('update:modelValue')).toEqual([[true]]);
    wrapper.unmount();
  });

  it('updates the accessible name when the translated setting title changes', async () => {
    const wrapper = mount(SettingsToggleSection, {
      props: { header: 'Appointment reminders', disabled: true },
    });

    await wrapper.setProps({ header: 'Напоминания о записи' });
    const control = wrapper.get('[role="switch"]');
    expect(control.attributes('aria-label')).toBe('Напоминания о записи');
    expect(control.attributes('disabled')).toBeDefined();
    wrapper.unmount();
  });
});
