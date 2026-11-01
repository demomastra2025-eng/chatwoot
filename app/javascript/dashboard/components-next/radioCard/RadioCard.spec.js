import { mount } from '@vue/test-utils';
import { defineComponent } from 'vue';
import RadioCard from './RadioCard.vue';

describe('RadioCard native radio contract', () => {
  it('names each radio and keeps a shared native group with distinct DOM ids', async () => {
    const wrapper = mount(
      defineComponent({
        components: { RadioCard },
        data: () => ({ selected: 'one' }),
        template: `<div>
        <RadioCard v-for="id in ['one', 'two']" :key="id" :id="id"
          name="choice" :label="id" :description="id + ' description'"
          :is-active="selected === id" @select="selected = $event" />
      </div>`,
      })
    );
    const inputs = wrapper.findAll('input[type="radio"]');
    expect(inputs.map(input => input.attributes('name'))).toEqual([
      'choice',
      'choice',
    ]);
    expect(inputs[0].attributes('id')).not.toBe(inputs[1].attributes('id'));
    inputs.forEach((input, index) => {
      expect(
        wrapper.get(`[id="${input.attributes('aria-labelledby')}"]`).text()
      ).toBe(['one', 'two'][index]);
      expect(
        wrapper.get(`[id="${input.attributes('aria-describedby')}"]`).text()
      ).toContain('description');
    });
    await inputs[1].setValue();
    expect(wrapper.vm.selected).toBe('two');
    expect(inputs[0].element.checked).toBe(false);
    expect(inputs[1].element.checked).toBe(true);
    wrapper.unmount();
  });

  it('emits the business value once for an input click and ignores disabled cards', async () => {
    const wrapper = mount(RadioCard, {
      attachTo: document.body,
      props: { id: 'fixed', name: 'mode', label: 'Fixed', description: 'Text' },
    });
    wrapper.get('input').element.click();
    expect(wrapper.emitted('select')).toEqual([['fixed']]);
    await wrapper.setProps({ disabled: true });
    await wrapper.trigger('click');
    expect(wrapper.emitted('select')).toHaveLength(1);
    wrapper.unmount();
  });
});
