import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const dispatchMock = vi.fn();
const useAlertMock = vi.fn();
const routerPushMock = vi.fn();
const basicBuildPayloadMock = vi.fn();
const systemBuildPayloadMock = vi.fn();

const assistantRecord = {
  id: 57,
  name: 'Voice assistant',
  usage_mode: 'external_agent',
  config: {
    feature_faq: true,
    handoff_message: 'old handoff',
    voice_settings: {
      provider: 'gemini-live',
      model: 'old-model',
      voice: 'old-voice',
    },
  },
};

const ButtonStub = defineComponent({
  name: 'NextButtonStub',
  props: {
    label: {
      type: String,
      default: '',
    },
  },
  emits: ['click'],
  setup(props, { emit }) {
    return () => h('button', { onClick: () => emit('click') }, props.label);
  },
});

const AssistantBasicSettingsFormStub = defineComponent({
  name: 'AssistantBasicSettingsForm',
  setup(_props, { expose }) {
    expose({ buildPayload: basicBuildPayloadMock });
    return () => h('div', 'basic-form');
  },
});

const AssistantSystemSettingsFormStub = defineComponent({
  name: 'AssistantSystemSettingsForm',
  setup(_props, { expose }) {
    expose({ buildPayload: systemBuildPayloadMock });
    return () => h('div', 'system-form');
  },
});

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => ({
    params: { accountId: '6', assistantId: '57' },
  }),
  useRouter: () => ({ push: routerPushMock }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: {
      'captainAssistants/getRecord': () => assistantRecord,
    },
  }),
  useMapGetter: key => {
    if (key === 'captainAssistants/getUIFlags') {
      return ref({ fetchingItem: false });
    }
    if (key === 'captainAssistants/getRecords') {
      return ref([assistantRecord]);
    }
    return ref({});
  },
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: {
    deleteAvatar: vi.fn(),
    updateAvatar: vi.fn(),
  },
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    setup(_props, { slots }) {
      return () => h('div', slots.body?.());
    },
  }),
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: ButtonStub,
}));

vi.mock(
  'dashboard/components-next/captain/pageComponents/settings/SettingsHeader.vue',
  () => ({
    default: defineComponent({ name: 'SettingsHeader', template: '<div />' }),
  })
);

vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantBasicSettingsForm.vue',
  () => ({ default: AssistantBasicSettingsFormStub })
);

vi.mock(
  'dashboard/components-next/captain/pageComponents/assistant/settings/AssistantSystemSettingsForm.vue',
  () => ({ default: AssistantSystemSettingsFormStub })
);

vi.mock(
  'dashboard/components-next/captain/pageComponents/DeleteDialog.vue',
  () => ({
    default: defineComponent({
      name: 'DeleteDialog',
      setup(_props, { expose }) {
        expose({ dialogRef: { open: vi.fn() } });
        return () => h('div', 'delete-dialog');
      },
    }),
  })
);

const { default: Settings } = await import('./Settings.vue');

const mountComponent = () => mount(Settings);

const clickUpdate = async wrapper => {
  const updateButton = wrapper
    .findAll('button')
    .find(button => button.text() === 'CAPTAIN.ASSISTANTS.FORM.UPDATE');

  await updateButton.trigger('click');
  await flushPromises();
};

describe('Captain assistant settings page', () => {
  beforeEach(() => {
    dispatchMock.mockReset();
    dispatchMock.mockResolvedValue({});
    useAlertMock.mockReset();
    routerPushMock.mockReset();

    basicBuildPayloadMock.mockReset();
    basicBuildPayloadMock.mockResolvedValue({
      assistant: {
        name: 'Voice assistant',
        description: 'Updated description',
        usage_mode: 'external_agent',
        config: {
          feature_faq: true,
        },
      },
    });

    systemBuildPayloadMock.mockReset();
    systemBuildPayloadMock.mockResolvedValue({
      assistant: {
        config: {
          handoff_message: '',
          temperature: 0.4,
          voice_settings: {
            provider: 'gemini-live',
            model: 'gemini-3.1-flash-live-preview',
            voice: 'sulafat',
            language: 'ru-KZ',
            system_prompt: '',
            first_message: '',
            transfer_message: '',
            max_duration_sec: 0,
            interruptions_enabled: false,
          },
        },
      },
    });
  });

  it('saves voice agent settings through the combined general save payload', async () => {
    const wrapper = mountComponent();

    await clickUpdate(wrapper);

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 57,
      name: 'Voice assistant',
      description: 'Updated description',
      usage_mode: 'external_agent',
      config: expect.objectContaining({
        feature_faq: true,
        handoff_message: '',
        temperature: 0.4,
        voice_settings: {
          provider: 'gemini-live',
          model: 'gemini-3.1-flash-live-preview',
          voice: 'sulafat',
          language: 'ru-KZ',
          system_prompt: '',
          first_message: '',
          transfer_message: '',
          max_duration_sec: 0,
          interruptions_enabled: false,
        },
      }),
    });
  });
});
