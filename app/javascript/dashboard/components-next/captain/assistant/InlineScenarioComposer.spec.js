import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';

import InlineScenarioComposer from './InlineScenarioComposer.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const inputStub = {
  name: 'Input',
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template:
    '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const textAreaStub = {
  name: 'TextArea',
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template:
    '<textarea :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const editorStub = {
  name: 'Editor',
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template:
    '<textarea :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const buttonStub = {
  name: 'Button',
  props: ['label', 'isLoading', 'disabled'],
  emits: ['click'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const cardLayoutStub = {
  name: 'CardLayout',
  template: '<div><slot /></div>',
};

const buildWrapper = () =>
  mount(InlineScenarioComposer, {
    global: {
      stubs: {
        Button: buttonStub,
        CardLayout: cardLayoutStub,
        Editor: editorStub,
        Input: inputStub,
        TextArea: textAreaStub,
      },
    },
  });

describe('InlineScenarioComposer', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('preserves the draft when creation is rejected', async () => {
    const wrapper = buildWrapper();

    await wrapper.find('input').setValue('Fallback handoff');
    const textareas = wrapper.findAll('textarea');
    await textareas[0].setValue('Use this when the request is unclear.');
    await textareas[1].setValue('Ask one question first.');

    await wrapper.findAll('button')[1].trigger('click');
    await flushPromises();

    const [payload, complete] = wrapper.emitted('add')[0];

    expect(payload).toMatchObject({
      title: 'Fallback handoff',
      description: 'Use this when the request is unclear.',
      instruction: 'Ask one question first.',
      enabled: true,
    });

    complete(false);
    await flushPromises();

    expect(wrapper.find('input').element.value).toBe('Fallback handoff');
    expect(wrapper.findAll('textarea')[0].element.value).toBe(
      'Use this when the request is unclear.'
    );
    expect(wrapper.findAll('textarea')[1].element.value).toBe(
      'Ask one question first.'
    );
  });

  it('resets the draft after a successful creation callback', async () => {
    const wrapper = buildWrapper();

    await wrapper.find('input').setValue('Fallback handoff');
    const textareas = wrapper.findAll('textarea');
    await textareas[0].setValue('Use this when the request is unclear.');
    await textareas[1].setValue('Ask one question first.');

    await wrapper.findAll('button')[1].trigger('click');
    await flushPromises();

    const [, complete] = wrapper.emitted('add')[0];
    complete(true);
    await flushPromises();

    expect(wrapper.find('input').element.value).toBe('');
    expect(wrapper.findAll('textarea')[0].element.value).toBe('');
    expect(wrapper.findAll('textarea')[1].element.value).toBe('');
  });
});
