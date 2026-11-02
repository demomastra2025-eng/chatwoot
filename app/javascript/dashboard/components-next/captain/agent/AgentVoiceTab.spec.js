import { describe, expect, it, vi, beforeEach } from 'vitest';
import { computed, defineComponent, h, ref } from 'vue';
import { shallowMount, flushPromises } from '@vue/test-utils';
import AgentVoiceTab from './AgentVoiceTab.vue';

const currentUser = ref({ captain_platform_access: true });
const update = vi.fn();
const buildPayload = vi.fn();
const dispatch = vi.fn();
const alert = vi.fn();
vi.mock('dashboard/api/captain/assistant', () => ({
  default: { update: (...args) => update(...args) },
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: () => computed(() => currentUser.value),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => alert(...args),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
const Form = defineComponent({
  setup(_, { expose }) {
    expose({ buildPayload: (...args) => buildPayload(...args) });
    return () => h('input');
  },
});
const mountTab = canEdit =>
  shallowMount(AgentVoiceTab, {
    props: {
      canEdit,
      assistant: {
        id: 7,
        config: { voice_settings: { provider: 'gemini-live' } },
      },
    },
    global: {
      stubs: { AssistantSystemSettingsForm: Form, VoiceAgentPreview: true },
    },
  });

describe('AgentVoiceTab save contract', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    currentUser.value = { captain_platform_access: true };
    buildPayload.mockResolvedValue({
      assistant: {
        config: { voice_settings: { voice: 'puck', first_message: 'Алло' } },
      },
    });
    update.mockResolvedValue({ data: { id: 7 } });
    dispatch.mockResolvedValue({ id: 7 });
  });

  it('denies clinic preview and save even when mounted directly', async () => {
    currentUser.value = {
      type: 'User',
      role: 'administrator',
      captain_platform_access: false,
    };
    const wrapper = mountTab(true);
    expect(wrapper.findComponent({ name: 'VoiceAgentPreview' }).exists()).toBe(
      false
    );
    expect(wrapper.find('[data-testid="agent-voice-save"]').exists()).toBe(
      false
    );
    expect(await wrapper.vm.save()).toBe(false);
    expect(buildPayload).not.toHaveBeenCalled();
    expect(update).not.toHaveBeenCalled();
  });

  it('prevents duplicate saves before async form validation completes', async () => {
    let finish;
    buildPayload.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          finish = resolve;
        })
    );
    const wrapper = mountTab(true);
    const first = wrapper.vm.save();
    expect(await wrapper.vm.save()).toBe(false);
    finish({ assistant: { config: { voice_settings: { voice: 'puck' } } } });
    expect(await first).toBe(true);
    expect(buildPayload).toHaveBeenCalledTimes(1);
    expect(update).toHaveBeenCalledExactlyOnceWith(7, {
      config: { voice_settings: { voice: 'puck' } },
    });
  });

  it('retains dirty state after an error and permits a successful retry', async () => {
    const wrapper = mountTab(true);
    await wrapper.find('input').trigger('input');
    update.mockRejectedValueOnce(new Error('Synthetic failure'));
    expect(await wrapper.vm.save()).toBe(false);
    expect(wrapper.vm.isDirty).toBe(true);
    expect(alert).toHaveBeenLastCalledWith(
      'CAPTAIN.ASSISTANTS.EDIT.ERROR_MESSAGE'
    );
    expect(await wrapper.vm.save()).toBe(true);
    await flushPromises();
    expect(wrapper.vm.isDirty).toBe(false);
    expect(update).toHaveBeenCalledTimes(2);
    expect(alert).toHaveBeenLastCalledWith(
      'CAPTAIN.ASSISTANTS.EDIT.SUCCESS_MESSAGE'
    );
  });
});
