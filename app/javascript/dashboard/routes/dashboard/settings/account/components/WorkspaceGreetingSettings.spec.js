import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import WorkspaceGreetingSettings from './WorkspaceGreetingSettings.vue';

const { storeDispatch, inboxesState } = vi.hoisted(() => ({
  storeDispatch: vi.fn(() => Promise.resolve()),
  inboxesState: {
    list: [
      {
        id: 1,
        name: 'WhatsApp Clinic',
        channel_type: 'Channel::Whatsapp',
        greeting_enabled: true,
        greeting_message: 'Здравствуйте!',
        captain_assistant: { name: 'Алия ИИ' },
      },
      {
        id: 2,
        name: 'Instagram Clinic',
        channel_type: 'Channel::Instagram',
        greeting_enabled: false,
        greeting_message: '',
      },
      {
        id: 3,
        name: 'Sipuni Voice',
        channel_type: 'Channel::Voice',
        greeting_enabled: true,
        greeting_message: 'Old voice greeting',
      },
    ],
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: (key, params) => (params?.name ? `${key}:${params.name}` : key) }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
  useMapGetter: () => ({ value: inboxesState.list }),
}));

describe('WorkspaceGreetingSettings', () => {
  beforeEach(() => {
    storeDispatch.mockClear();
  });

  it('excludes voice and email channels from the text channels list and shows AI badge', () => {
    const wrapper = mount(WorkspaceGreetingSettings, {
      global: {
        stubs: {
          SectionLayout: {
            template: '<section><slot /></section>',
          },
          Button: {
            props: ['label'],
            template: '<button @click="$emit(\'click\')">{{ label }}</button>',
          },
        },
      },
    });

    expect(wrapper.text()).toContain('WhatsApp Clinic');
    expect(wrapper.text()).toContain('Instagram Clinic');
    expect(wrapper.text()).not.toContain('Sipuni Voice');
    expect(wrapper.text()).toContain('Алия ИИ');
  });

  it('updates text channels and disables greeting on voice channels when saved', async () => {
    const wrapper = mount(WorkspaceGreetingSettings, {
      global: {
        stubs: {
          SectionLayout: {
            template: '<section><slot /></section>',
          },
          Button: {
            props: ['label'],
            template: '<button @click="$emit(\'click\')">{{ label }}</button>',
          },
        },
      },
    });

    await wrapper.find('[data-test="workspace-greeting-message"]').setValue('Добрый день!');
    await wrapper.find('[data-test="workspace-greeting-save"]').trigger('click');
    await flushPromises();

    expect(storeDispatch).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 1,
      formData: false,
      greeting_enabled: true,
      greeting_message: 'Добрый день!',
    });
    expect(storeDispatch).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 3,
      formData: false,
      greeting_enabled: false,
      greeting_message: 'Old voice greeting',
    });
  });
});
