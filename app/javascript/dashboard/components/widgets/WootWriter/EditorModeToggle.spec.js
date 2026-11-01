import { mount } from '@vue/test-utils';
import EditorModeToggle from './EditorModeToggle.vue';
import { REPLY_EDITOR_MODES } from './constants';

describe('EditorModeToggle', () => {
  it('announces private note as a toggle state and preserves its action', async () => {
    const wrapper = mount(EditorModeToggle, {
      props: { mode: REPLY_EDITOR_MODES.REPLY },
    });
    const button = wrapper.get('button');
    expect(button.attributes('type')).toBe('button');
    expect(button.attributes('aria-pressed')).toBe('false');
    const label = button.attributes('aria-label');
    expect(label).toBeTruthy();
    await button.trigger('click');
    expect(wrapper.emitted('toggleMode')).toEqual([[]]);
    await wrapper.setProps({ mode: REPLY_EDITOR_MODES.NOTE });
    expect(button.attributes('aria-pressed')).toBe('true');
    expect(button.attributes('aria-label')).toBe(label);
    wrapper.unmount();
  });

  it('announces the forced private mode and blocks restricted/disabled actions', async () => {
    const wrapper = mount(EditorModeToggle, {
      props: { mode: REPLY_EDITOR_MODES.REPLY, isReplyRestricted: true },
    });
    const button = wrapper.get('button');
    expect(button.attributes('aria-pressed')).toBe('true');
    expect(button.element.disabled).toBe(true);
    await button.trigger('click');
    expect(wrapper.emitted('toggleMode')).toBeUndefined();
    await wrapper.setProps({ isReplyRestricted: false, disabled: true });
    await button.trigger('click');
    expect(wrapper.emitted('toggleMode')).toBeUndefined();
    wrapper.unmount();
  });
});
