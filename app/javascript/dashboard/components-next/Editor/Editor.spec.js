import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';

import Editor from './Editor.vue';

const wootEditorStub = {
  name: 'WootEditor',
  props: ['modelValue', 'overrideLineBreaks'],
  emits: ['input', 'focus', 'blur', 'executeCopilotAction'],
  template: '<div data-testid="woot-editor" />',
};

const buildWrapper = props =>
  mount(Editor, {
    props: {
      modelValue: 'Hello',
      ...props,
    },
    global: {
      stubs: {
        WootEditor: wootEditorStub,
      },
    },
  });

describe('Editor', () => {
  it('keeps WootEditor line-break override disabled by default', () => {
    const wrapper = buildWrapper();

    expect(
      wrapper.findComponent(wootEditorStub).props('overrideLineBreaks')
    ).toBe(false);
  });

  it('passes line-break override through to WootEditor', () => {
    const wrapper = buildWrapper({ overrideLineBreaks: true });

    expect(
      wrapper.findComponent(wootEditorStub).props('overrideLineBreaks')
    ).toBe(true);
  });
});
