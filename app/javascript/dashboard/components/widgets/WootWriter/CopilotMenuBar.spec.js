import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import CopilotMenuBar from './CopilotMenuBar.vue';
import { REPLY_EDITOR_MODES } from './constants';

const testState = vi.hoisted(() => ({
  replyMode: null,
  draftMessage: null,
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => testState.replyMode,
}));

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({ draftMessage: testState.draftMessage }),
}));

const ButtonStub = {
  name: 'Button',
  props: ['label', 'icon'],
  emits: ['click'],
  template:
    '<button type="button" :data-label="label" @click="$emit(\'click\')"><slot /></button>',
};

const DropdownBodyStub = {
  name: 'DropdownBody',
  template: '<div class="dropdown-body"><slot /></div>',
};

const mountMenu = props =>
  mount(CopilotMenuBar, {
    props,
    global: {
      stubs: {
        Button: ButtonStub,
        DropdownBody: DropdownBodyStub,
        Icon: true,
      },
    },
  });

const labels = wrapper =>
  wrapper.findAll('button').map(button => button.attributes('data-label'));

describe('CopilotMenuBar', () => {
  beforeEach(() => {
    testState.replyMode = ref(REPLY_EDITOR_MODES.REPLY);
    testState.draftMessage = ref('');
  });

  it('keeps the AI writing tools and has no Copilot chat entry', () => {
    const wrapper = mountMenu({
      conversationId: 12,
      editorContent: 'Hello, we will check it',
    });

    expect(labels(wrapper)).toEqual([
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.IMPROVE_REPLY',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.TITLE',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.PROFESSIONAL',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.CASUAL',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.STRAIGHTFORWARD',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.CONFIDENT',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.FRIENDLY',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.GRAMMAR',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUGGESTION',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUMMARIZE',
    ]);
    expect(wrapper.html()).not.toContain('ASK_COPILOT');
    expect(wrapper.find('.bg-n-strong').exists()).toBe(true);
    expect(wrapper.text()).not.toContain(
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.EMPTY_HINT'
    );
  });

  it('emits the selected AI writing action', async () => {
    const wrapper = mountMenu({ conversationId: 12, editorContent: '' });

    await wrapper
      .find(
        '[data-label="INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUGGESTION"]'
      )
      .trigger('click');
    await wrapper
      .find(
        '[data-label="INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUMMARIZE"]'
      )
      .trigger('click');

    expect(wrapper.emitted('executeCopilotAction')).toEqual([
      ['reply_suggestion'],
      ['summarize'],
    ]);
  });

  it('shows only the rewrite tools outside a conversation', () => {
    const wrapper = mountMenu({ editorContent: 'Draft for a new contact' });

    expect(labels(wrapper)).toContain(
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.GRAMMAR'
    );
    expect(labels(wrapper)).not.toContain(
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUGGESTION'
    );
    expect(wrapper.find('.bg-n-strong').exists()).toBe(false);
  });

  it('shows a hint instead of an empty menu when no AI action applies yet', () => {
    const wrapper = mountMenu({ editorContent: '' });

    expect(wrapper.findAll('button')).toHaveLength(0);
    expect(wrapper.find('.bg-n-strong').exists()).toBe(false);
    expect(wrapper.text()).toContain(
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.EMPTY_HINT'
    );
  });
});
