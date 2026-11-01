import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

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

const wrappers = [];
const mountMenu = props => {
  const wrapper = mount(CopilotMenuBar, {
    attachTo: document.body,
    props,
    global: {
      stubs: {
        Button: ButtonStub,
        DropdownBody: DropdownBodyStub,
        Icon: true,
      },
    },
  });
  wrappers.push(wrapper);
  return wrapper;
};

const labels = wrapper =>
  wrapper.findAll('button').map(button => button.attributes('data-label'));

describe('CopilotMenuBar', () => {
  beforeEach(() => {
    testState.replyMode = ref(REPLY_EDITOR_MODES.REPLY);
    testState.draftMessage = ref('');
  });
  afterEach(() => {
    wrappers.splice(0).forEach(wrapper => wrapper.unmount());
  });

  it('keeps the AI writing tools and opens tone options explicitly', async () => {
    const wrapper = mountMenu({
      conversationId: 12,
      editorContent: 'Hello, we will check it',
    });

    expect(labels(wrapper)).toEqual([
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.IMPROVE_REPLY',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.TITLE',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.GRAMMAR',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUGGESTION',
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.SUMMARIZE',
    ]);
    expect(wrapper.html()).not.toContain('ASK_COPILOT');
    expect(wrapper.find('.bg-n-strong').exists()).toBe(true);
    expect(wrapper.text()).not.toContain(
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.EMPTY_HINT'
    );
    const trigger = wrapper.find(
      '[data-label="INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.TITLE"]'
    );
    expect(trigger.attributes('aria-expanded')).toBe('false');
    await trigger.trigger('click');
    expect(trigger.attributes('aria-expanded')).toBe('true');
    expect(labels(wrapper)).toContain(
      'INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.PROFESSIONAL'
    );
    expect(wrapper.emitted('executeCopilotAction')).toBeUndefined();
    await trigger.trigger('click');
    expect(trigger.attributes('aria-expanded')).toBe('false');
  });

  it('opens the tone choices with the keyboard and restores focus on Escape', async () => {
    const wrapper = mountMenu({ editorContent: 'A synthetic draft' });
    const trigger = wrapper.find('[aria-controls]');
    trigger.element.focus();
    await trigger.trigger('keydown', { key: 'ArrowDown' });
    const option = wrapper.find(
      '[data-label="INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.PROFESSIONAL"]'
    );
    expect(document.activeElement).toBe(option.element);
    await option.trigger('keydown', { key: 'Escape' });
    expect(trigger.attributes('aria-expanded')).toBe('false');
    expect(document.activeElement).toBe(trigger.element);
    expect(wrapper.emitted('executeCopilotAction')).toBeUndefined();
  });

  it('emits the selected tone once and closes its choices', async () => {
    const wrapper = mountMenu({ editorContent: 'A synthetic draft' });
    await wrapper.find('[aria-controls]').trigger('click');
    await wrapper
      .find(
        '[data-label="INTEGRATION_SETTINGS.OPEN_AI.REPLY_OPTIONS.CHANGE_TONE.OPTIONS.CASUAL"]'
      )
      .trigger('click');
    expect(wrapper.emitted('executeCopilotAction')).toEqual([['casual']]);
    expect(wrapper.find('[aria-controls]').attributes('aria-expanded')).toBe(
      'false'
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
