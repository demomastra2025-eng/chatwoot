import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';

import ConversationVisibilitySettings from './ConversationVisibilitySettings.vue';

const updateUISettings = vi.fn();

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: ref({}),
    updateUISettings,
  }),
}));

const mountComponent = () =>
  shallowMount(ConversationVisibilitySettings, {
    global: {
      stubs: {
        BaseSettingsHeader: {
          props: ['title', 'description'],
          template:
            '<header data-test="settings-header" :data-title="title" :data-description="description" />',
        },
        SettingsLayout: {
          template:
            '<section><slot name="header" /><slot name="body" /><slot /></section>',
        },
        Switch: {
          props: ['id', 'modelValue', 'disabled'],
          emits: ['update:modelValue'],
          template:
            '<input data-test="visibility-switch" type="checkbox" :id="id" :checked="modelValue" :disabled="disabled" @change="$emit(\'update:modelValue\', $event.target.checked)" />',
        },
        Button: true,
      },
    },
  });

describe('ConversationVisibilitySettings', () => {
  beforeEach(() => {
    updateUISettings.mockClear();
  });

  it('shows a visibility toggle for CRM pipeline filters in dialog settings', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.PIPELINE'
    );
  });
});
