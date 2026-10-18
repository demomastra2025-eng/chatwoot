import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import WorkspaceCsatSettings from './WorkspaceCsatSettings.vue';

const { storeDispatch, inboxesState } = vi.hoisted(() => ({
  storeDispatch: vi.fn(() => Promise.resolve()),
  inboxesState: {
    list: [
      {
        id: 1,
        name: 'WhatsApp Clinic',
        channel_type: 'Channel::Whatsapp',
        csat_survey_enabled: true,
        csat_config: { display_type: 'emoji', message: 'Оцените диалог' },
      },
      {
        id: 3,
        name: 'Sipuni Voice',
        channel_type: 'Channel::Voice',
        csat_survey_enabled: true,
        csat_config: {},
      },
    ],
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
  useMapGetter: () => ({ value: inboxesState.list }),
}));

describe('WorkspaceCsatSettings', () => {
  beforeEach(() => {
    storeDispatch.mockClear();
  });

  it('excludes voice channels and saves CSAT settings across text channels', async () => {
    const wrapper = mount(WorkspaceCsatSettings, {
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
    expect(wrapper.text()).not.toContain('Sipuni Voice');

    await wrapper.find('[data-test="workspace-csat-message"]').setValue('Спасибо за обращение! Оцените нас.');
    await wrapper.find('[data-test="workspace-csat-save"]').trigger('click');
    await flushPromises();

    expect(storeDispatch).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 1,
      formData: false,
      csat_survey_enabled: true,
      csat_config: {
        display_type: 'emoji',
        message: 'Спасибо за обращение! Оцените нас.',
      },
    });
    expect(storeDispatch).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 3,
      formData: false,
      csat_survey_enabled: false,
      csat_config: {},
    });
  });
});
