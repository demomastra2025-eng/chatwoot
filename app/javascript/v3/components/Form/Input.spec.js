import { mount } from '@vue/test-utils';
import FormInput from './Input.vue';
import FormSelect from './Select.vue';

describe('V3 form labels', () => {
  const wrappers = [];
  const renderInput = props => {
    const wrapper = mount(FormInput, {
      props: { name: 'email', label: 'Email', modelValue: '', ...props },
      attachTo: document.body,
      global: { stubs: { 'fluent-icon': true } },
    });
    wrappers.push(wrapper);
    return wrapper;
  };

  afterEach(() => {
    wrappers.forEach(wrapper => wrapper.unmount());
    wrappers.length = 0;
  });

  it('associates each label with its own input even when names repeat', () => {
    const wrapper = mount(
      {
        components: { FormInput },
        template:
          '<div><FormInput name="email" label="Email" model-value="" /><FormInput name="email" label="Email" model-value="" /></div>',
      },
      { attachTo: document.body, global: { stubs: { 'fluent-icon': true } } }
    );
    wrappers.push(wrapper);
    const [first, second] = wrapper.findAllComponents(FormInput);
    const firstInput = first.get('input').element;
    const secondInput = second.get('input').element;

    expect(firstInput.id).toBeTruthy();
    expect(firstInput.id).not.toBe(secondInput.id);
    expect(first.get('label').element.control).toBe(firstInput);
    expect(second.get('label').element.control).toBe(secondInput);
    expect(Array.from(firstInput.labels)).toEqual([first.get('label').element]);
  });

  it('preserves an explicit id and the association after editing the value', async () => {
    const wrapper = renderInput({ id: 'login-email' });
    await wrapper.get('input').setValue('demo@example.test');

    expect(wrapper.get('label').attributes('for')).toBe('login-email');
    expect(wrapper.get('label').element.control).toBe(
      wrapper.get('input').element
    );
    expect(wrapper.emitted('update:modelValue')).toEqual([
      ['demo@example.test'],
    ]);
  });

  it('keeps a password label associated after the field is filled', async () => {
    const wrapper = renderInput({
      name: 'password',
      label: 'Password',
      type: 'password',
      modelValue: 'example-password',
    });
    await wrapper.get('input').setValue('updated-example-password');
    expect(wrapper.get('input').element.type).toBe('password');
    expect(wrapper.get('label').element.control).toBe(
      wrapper.get('input').element
    );
    expect(wrapper.get('label').text()).toBe('Password');
  });

  it('also associates the existing WithLabel select consumer', () => {
    const wrapper = mount(FormSelect, {
      props: {
        name: 'language',
        label: 'Language',
        modelValue: 'en',
        options: [{ value: 'en', label: 'English' }],
      },
      global: {
        stubs: { 'fluent-icon': true },
        directives: { onClickaway: () => {} },
      },
    });
    wrappers.push(wrapper);

    expect(wrapper.get('label').element.control).toBe(
      wrapper.get('select').element
    );
  });
});
