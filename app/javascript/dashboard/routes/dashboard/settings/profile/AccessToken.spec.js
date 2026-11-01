import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import AccessToken from './AccessToken.vue';

describe('AccessToken', () => {
  it('keeps a fake token readonly, names visibility and copies only on request', async () => {
    const wrapper = mount(AccessToken, {
      props: { value: 'synthetic-api-token' },
      global: { stubs: { NextButton: false } },
    });
    const input = wrapper.get('input');
    expect(input.attributes('type')).toBe('password');
    expect(input.attributes('readonly')).toBeDefined();
    const toggle = wrapper.get('button[aria-label="Show token"]');
    await toggle.trigger('click');
    expect(input.attributes('type')).toBe('text');
    expect(
      wrapper.get('button[aria-label="Hide token"]').attributes('aria-pressed')
    ).toBe('true');
    expect(wrapper.emitted('onCopy')).toBeUndefined();
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Copy')
      .trigger('click');
    expect(wrapper.emitted('onCopy')).toEqual([['synthetic-api-token']]);
    await wrapper.get('button[aria-label="Hide token"]').trigger('click');
    expect(input.attributes('type')).toBe('password');
  });

  it('requires the existing reset confirmation and can omit reset', async () => {
    const wrapper = mount(AccessToken, {
      props: { value: 'synthetic-api-token' },
      global: { stubs: { NextButton: false } },
    });
    const reset = wrapper
      .findAll('button')
      .find(button => button.text() === 'Reset');
    await reset.trigger('click');
    expect(wrapper.emitted('onReset')).toBeUndefined();
    await reset.trigger('click');
    expect(wrapper.emitted('onReset')).toHaveLength(1);
    await wrapper.setProps({ showResetButton: false });
    expect(wrapper.text()).not.toContain('Reset');
  });
});
