import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import SchedulingContactPhoneEditor from './SchedulingContactPhoneEditor.vue';

vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key }),
}));

const stubs = {
  Button: {
    props: ['label', 'disabled'],
    template:
      '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
  },
  PhoneNumberInput: {
    inheritAttrs: false,
    props: ['modelValue', 'disabled'],
    template:
      '<input :value="modelValue" :disabled="disabled" @input="$emit(\'update:modelValue\', $event.target.value)" />',
  },
};
const render = props =>
  mount(SchedulingContactPhoneEditor, {
    props,
    global: { stubs, mocks: { $t: key => key } },
  });

describe('SchedulingContactPhoneEditor', () => {
  it('keeps the phone inline and opens the existing editor from change', async () => {
    const wrapper = render({ phone: '+77010000001', inlineSummary: true });
    expect(
      wrapper.get('[data-test="contact-phone-editor"]').element.tagName
    ).toBe('SPAN');
    expect(wrapper.text()).toContain(
      '· +77010000001 · SCHEDULING.CONTACT.CHANGE_PHONE_INLINE'
    );
    expect(wrapper.text()).not.toContain('SCHEDULING.CONTACT.PHONE');

    await wrapper.get('button').trigger('click');
    expect(wrapper.get('input').element.value).toBe('+77010000001');
  });

  it('shows add for an empty phone and validates before emitting a save', async () => {
    const wrapper = render({ phone: '' });
    await wrapper.get('button').trigger('click');
    await wrapper.get('input').setValue('123');
    await wrapper.findAll('button')[0].trigger('click');
    expect(wrapper.emitted('save')).toBeUndefined();
    expect(wrapper.text()).toContain(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED'
    );

    await wrapper.get('input').setValue('+77010000001');
    await wrapper.findAll('button')[0].trigger('click');
    expect(wrapper.emitted('save')[0]).toEqual(['+77010000001']);
  });

  it('shows change for an existing phone, cancels, and disables editing while saving', async () => {
    const wrapper = render({ phone: '+77010000001' });
    expect(wrapper.text()).toContain('+77010000001');
    await wrapper.get('button').trigger('click');
    expect(wrapper.get('input').element.value).toBe('+77010000001');
    await wrapper.setProps({ saving: true });
    expect(wrapper.get('input').attributes('disabled')).toBeDefined();
    expect(
      wrapper
        .findAll('button')
        .every(button => button.attributes('disabled') !== undefined)
    ).toBe(true);
    await wrapper.setProps({ saving: false });
    await wrapper.findAll('button')[1].trigger('click');
    expect(wrapper.find('input').exists()).toBe(false);
  });

  it('clears the draft when switching to another contact with the same phone', async () => {
    const wrapper = render({ contactId: 1, phone: '' });
    await wrapper.get('button').trigger('click');
    await wrapper.get('input').setValue('+77010000001');

    await wrapper.setProps({ contactId: 2 });

    expect(wrapper.find('input').exists()).toBe(false);
    await wrapper.get('button').trigger('click');
    expect(wrapper.get('input').element.value).toBe('');
  });
});
