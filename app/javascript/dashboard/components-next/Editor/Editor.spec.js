import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';

import Editor from './Editor.vue';

const wootEditorStub = {
  name: 'WootEditor',
  props: ['modelValue', 'overrideLineBreaks', 'disabled'],
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

  it('applies explicit auto-height styles without disabling the editor', () => {
    const wrapper = buildWrapper({
      autoHeight: true,
      editorKey: 'captain:assistant:58:basic-description',
      minHeight: '19rem',
      maxHeight: '42rem',
    });

    const editorWrapper = wrapper.find('.editor-wrapper');
    const wootEditor = wrapper.findComponent(wootEditorStub);

    expect(editorWrapper.classes()).toContain('editor-wrapper--auto-height');
    expect(editorWrapper.attributes('style')).toContain(
      '--editor-min-height: 19rem;'
    );
    expect(editorWrapper.attributes('style')).toContain(
      '--editor-max-height: 42rem;'
    );
    expect(wootEditor.classes()).toContain('auto-height-editor-wrapper');
    expect(wootEditor.props('disabled')).toBe(false);
    expect(wrapper.find('.cursor-not-allowed').exists()).toBe(false);
  });
});
