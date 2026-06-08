import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import { describe, expect, it, vi } from 'vitest';

import ReplyTopPanel from './ReplyTopPanel.vue';
import { REPLY_EDITOR_MODES } from './constants';

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    captainTasksEnabled: ref(true),
  }),
}));

vi.mock('dashboard/composables', () => ({
  useTrack: vi.fn(),
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
        CopilotMenuBar: true,
      },
    },
  });

describe('ReplyTopPanel', () => {
  it('shows the Captain copilot menu trigger by default', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-icon="i-ph-sparkle-fill"]').exists()).toBe(true);
  });

  it('can hide the Captain copilot menu trigger while keeping editor actions', () => {
    const wrapper = mountComponent({ showCopilotActions: false });

    expect(wrapper.find('[data-icon="i-ph-sparkle-fill"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-icon="i-lucide-maximize-2"]').exists()).toBe(
      true
    );
  });
});
