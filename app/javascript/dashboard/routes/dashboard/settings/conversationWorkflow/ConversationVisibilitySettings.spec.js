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

  it('shows a visibility toggle for appointment filters in dialog settings', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.SECTIONS.APPOINTMENTS'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENTS'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.SCHEDULED'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.CONFIRMED'
    );
    expect(wrapper.text()).toContain(
      'CONVERSATION_WORKFLOW.VISIBILITY.ITEMS.APPOINTMENT_STATUSES.COMPLETED'
    );
  });

  it('disables appointment status toggles when the appointments group is hidden', async () => {
    const wrapper = mountComponent();

    wrapper.vm.visibilityDraft['Conversation:AppointmentStatuses'] = false;
    await wrapper.vm.$nextTick();

    expect(
      wrapper
        .find(
          '#conversation-visibility-conversation-appointmentstatus-scheduled'
        )
        .attributes('disabled')
    ).toBeDefined();
  });
});
