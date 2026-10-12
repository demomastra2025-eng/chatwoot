import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import TagInput from './TagInput.vue';

const longTag =
  'Не заявка — информационный вопрос (адрес / график / результаты)';

const mountTagInput = (props = {}) =>
  mount(TagInput, {
    props: { modelValue: [longTag], allowCreate: true, ...props },
  });

describe('TagInput', () => {
  it('truncates chips on a single line by default', () => {
    const wrapper = mountTagInput();

    const label = wrapper.get('span.truncate');
    const chip = label.element.parentElement;
    expect(label.text()).toBe(longTag);
    expect(label.classes()).not.toContain('!whitespace-normal');
    expect(chip.classList).toContain('h-7');
    expect(chip.classList).not.toContain('!h-auto');
  });

  it('keeps the 200px minimum for the new tag input by default', async () => {
    const wrapper = mountTagInput();

    await wrapper.trigger('click');
    const inputWrapper = wrapper
      .get('input')
      .element.closest('.min-w-\\[200px\\]');
    expect(inputWrapper).not.toBeNull();
    expect(inputWrapper.classList).not.toContain('!min-w-full');
  });

  it('applies opt-in chip and input wrapper classes', async () => {
    const wrapper = mountTagInput({
      tagClass: '!h-auto min-h-7',
      tagLabelClass: '!whitespace-normal break-words',
      inputWrapperClass: '!min-w-full',
    });

    const label = wrapper.get('span.truncate');
    expect(label.classes()).toEqual(
      expect.arrayContaining(['!whitespace-normal', 'break-words'])
    );
    expect([...label.element.parentElement.classList]).toEqual(
      expect.arrayContaining(['!h-auto', 'min-h-7'])
    );

    await wrapper.trigger('click');
    const inputWrapper = wrapper
      .get('input')
      .element.closest('.min-w-\\[200px\\]');
    expect(inputWrapper.classList).toContain('!min-w-full');
  });
});
