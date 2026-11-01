import { mount, flushPromises } from '@vue/test-utils';
import { h } from 'vue';
import EmojiInput from './EmojiInput.vue';
import Button from 'dashboard/components-next/button/Button.vue';

describe('EmojiInput inside a form', () => {
  it('removes an icon without submitting its parent form', async () => {
    const submit = vi.fn(event => event.preventDefault());
    const remove = vi.fn();
    const wrapper = mount(
      {
        render: () =>
          h('form', { onSubmit: submit }, [
            h(EmojiInput, {
              showRemoveButton: true,
              inline: true,
              onClick: remove,
            }),
          ]),
      },
      { attachTo: document.body, global: { stubs: { NextButton: false } } }
    );
    await flushPromises();
    const action = wrapper.getComponent(Button);
    const enter = new KeyboardEvent('keydown', {
      key: 'Enter',
      bubbles: true,
      cancelable: true,
    });
    wrapper.get('input').element.dispatchEvent(enter);
    expect(enter.defaultPrevented).toBe(true);
    expect(action.get('button').attributes('type')).toBe('button');
    action.get('button').element.click();
    await flushPromises();
    expect(remove).toHaveBeenCalledWith('');
    expect(submit).not.toHaveBeenCalled();
    wrapper.unmount();
  });
});
