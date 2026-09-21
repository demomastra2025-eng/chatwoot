import { shallowMount } from '@vue/test-utils';

import { describe, expect, it, vi } from 'vitest';

import ReplyTopPanel from './ReplyTopPanel.vue';
import { REPLY_EDITOR_MODES } from './constants';

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

const NextButtonStub = {
  name: 'NextButton',
  props: ['icon'],
  template: '<button type="button" :data-icon="icon" />',
};

const mountComponent = props =>
  shallowMount(ReplyTopPanel, {
    props: {
      mode: REPLY_EDITOR_MODES.REPLY,
      conversationId: 1,
      ...props,
    },
    global: {
      stubs: {
        NextButton: NextButtonStub,
        EditorModeToggle: true,
      },
    },
  });

describe('ReplyTopPanel', () => {
  it('keeps the editor size action available', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-icon="i-lucide-maximize-2"]').exists()).toBe(
      true
    );
  });
});
