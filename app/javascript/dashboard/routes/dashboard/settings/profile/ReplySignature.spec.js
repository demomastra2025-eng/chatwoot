import { mount } from '@vue/test-utils';
import ReplySignature from './ReplySignature.vue';

describe('ReplySignature', () => {
  it('submits the edited signature and permits clearing it', async () => {
    const wrapper = mount(ReplySignature, {
      props: { modelValue: 'Old signature' },
      global: { mocks: { $t: key => key } },
    });

    await wrapper.find('input').setValue('  Clinic Test, operator Ana  ');
    await wrapper.find('form').trigger('submit');
    expect(wrapper.emitted('save')[0]).toEqual(['Clinic Test, operator Ana']);

    await wrapper.setProps({ modelValue: '' });
    await wrapper.find('form').trigger('submit');
    expect(wrapper.emitted('save')[1]).toEqual(['']);
  });
});
