import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick, reactive, ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const dispatchMock = vi.fn();
const useAlertMock = vi.fn();
const routerPushMock = vi.fn();
const routerReplaceMock = vi.fn();
const leaveGuards = [];
const updateGuards = [];
const policy = { isAdmin: true };

const route = reactive({
  name: 'captain_agent_show',
  params: { accountId: '3', assistantId: '12' },
  query: {},
});

const buildAssistant = () => ({
  id: 12,
  name: 'Администратор',
  routing_description: 'Записывает пациентов',
  description: 'Отвечай вежливо.',
  active: true,
  config: {
    model: '',
    thinking_effort: 'low',
    temperature: null,
    follow_up_settings: { enabled: true, steps: [{ delay: 1 }] },
  },
});
const assistantRecord = ref(buildAssistant());

const configStore = {
  fetch: vi.fn(),
  getModelsForFeature: () => [
    {
      id: 'default-model',
      supports_temperature: false,
      reasoning_efforts: ['low', 'high'],
    },
    {
      id: 'smart-model',
      supports_temperature: true,
      reasoning_efforts: ['low'],
    },
  ],
  getSelectedModelForFeature: () => 'default-model',
};
const matrixStore = { fetch: vi.fn() };

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => route,
  useRouter: () => ({ push: routerPushMock, replace: routerReplaceMock }),
  onBeforeRouteLeave: guard => leaveGuards.push(guard),
  onBeforeRouteUpdate: guard => updateGuards.push(guard),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => useAlertMock(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
    getters: {
      'captainAssistants/getRecord': () => assistantRecord.value,
      'inboxes/getInboxes': [],
    },
  }),
  useMapGetter: key =>
    key === 'captainAssistants/getUIFlags'
      ? ref({ fetchingItem: false })
      : ref([]),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => policy.isAdmin,
    shouldShowPaywall: () => false,
  }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isCloudFeatureEnabled: () => true }),
}));

vi.mock('dashboard/store/captain/preferences', () => ({
  useCaptainConfigStore: () => configStore,
}));

vi.mock('dashboard/store/captain/channelMatrix', () => ({
  useCaptainChannelMatrixStore: () => matrixStore,
}));

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { updateAvatar: vi.fn(), deleteAvatar: vi.fn(), delete: vi.fn() },
}));

vi.mock('dashboard/components-next/captain/agent/useAgentActiveToggle', () => ({
  useAgentActiveToggle: () => ({
    setActive: vi.fn(async () => true),
    isToggling: () => false,
  }),
}));

vi.mock('dashboard/components-next/captain/agent/agentVoice', () => ({
  isVoiceAgent: () => false,
}));

// The tests emit the tab events themselves, so the stub declares none.
const simpleStub = name =>
  defineComponent({
    name,
    props: {
      assistant: { type: Object, default: null },
      draft: { type: Object, default: null },
    },
    setup(props) {
      return () =>
        h(
          'div',
          {
            'data-stub': name,
            'data-assistant-id': props.assistant?.id,
            'data-draft-name': props.draft?.name,
          },
          name
        );
    },
  });

vi.mock(
  'dashboard/components-next/captain/agent/AgentInstructionTab.vue',
  () => ({ default: simpleStub('AgentInstructionTab') })
);
vi.mock(
  'dashboard/components-next/captain/agent/AgentFollowUpsTab.vue',
  () => ({ default: simpleStub('AgentFollowUpsTab') })
);
vi.mock('dashboard/components-next/captain/agent/AgentCheckTab.vue', () => ({
  default: simpleStub('AgentCheckTab'),
}));
vi.mock('dashboard/components-next/captain/agent/AgentVoiceTab.vue', () => ({
  default: simpleStub('AgentVoiceTab'),
}));
vi.mock(
  'dashboard/components-next/captain/agent/AgentDeleteDialog.vue',
  () => ({
    default: defineComponent({
      name: 'AgentDeleteDialog',
      setup(_props, { expose }) {
        expose({ open: vi.fn() });
        return () => h('div');
      },
    }),
  })
);
vi.mock('dashboard/components-next/captain/pageComponents/Paywall.vue', () => ({
  default: defineComponent({ name: 'CaptainPaywall', render: () => null }),
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    setup(_props, { slots }) {
      return () =>
        h('div', [
          slots.header?.({ showPaywall: false }),
          slots.subHeader?.(),
          slots.body?.(),
        ]);
    },
  }),
}));

vi.mock('dashboard/components-next/tabbar/TabBar.vue', () => ({
  default: defineComponent({
    name: 'TabBar',
    props: {
      tabs: { type: Array, default: () => [] },
    },
    emits: ['tabChanged'],
    setup(props, { emit }) {
      return () =>
        h(
          'div',
          props.tabs.map(tab =>
            h(
              'button',
              { 'data-tab': tab.key, onClick: () => emit('tabChanged', tab) },
              tab.label
            )
          )
        );
    },
  }),
}));

const InputStub = defineComponent({
  name: 'InputStub',
  inheritAttrs: false,
  props: {
    modelValue: { type: [String, Number], default: '' },
    message: { type: String, default: '' },
  },
  emits: ['update:modelValue'],
  setup(props, { emit, attrs }) {
    return () =>
      h('div', [
        h('input', {
          'data-test': attrs['data-test'],
          value: props.modelValue,
          onInput: event => emit('update:modelValue', event.target.value),
        }),
        props.message ? h('p', props.message) : null,
      ]);
  },
});

const ButtonStub = defineComponent({
  name: 'ButtonStub',
  props: {
    label: { type: String, default: '' },
    disabled: { type: Boolean, default: false },
  },
  emits: ['click'],
  setup(props, { emit }) {
    return () =>
      h(
        'button',
        { disabled: props.disabled, onClick: () => emit('click') },
        props.label
      );
  },
});

const { default: AgentPage } = await import('./AgentPage.vue');

const mountPage = () =>
  mount(AgentPage, {
    global: {
      stubs: {
        Input: InputStub,
        Button: ButtonStub,
        Avatar: true,
        Switch: true,
        DropdownMenu: true,
        RouterLink: { props: ['to'], template: '<a><slot /></a>' },
      },
      directives: { 'on-clickaway': {} },
    },
  });

const saveButton = wrapper => wrapper.find('[data-test="agent-save"]');
const instructionTab = wrapper =>
  wrapper.findComponent({ name: 'AgentInstructionTab' });

describe('Agent page', () => {
  beforeEach(() => {
    policy.isAdmin = true;
    route.query = {};
    route.params = { accountId: '3', assistantId: '12' };
    assistantRecord.value = buildAssistant();
    leaveGuards.length = 0;
    updateGuards.length = 0;
    matrixStore.fetch.mockClear();
    configStore.fetch.mockClear();
    routerPushMock.mockReset();
    routerReplaceMock.mockReset();
    useAlertMock.mockReset();
    dispatchMock.mockReset();
    dispatchMock.mockImplementation(async (action, payload) => {
      if (action !== 'captainAssistants/update') return {};
      const { id, config, ...fields } = payload;
      const saved = {
        ...assistantRecord.value,
        ...fields,
        id,
        config: { ...assistantRecord.value.config, ...(config || {}) },
      };
      assistantRecord.value = saved;
      return saved;
    });
  });

  it('keeps «Сохранить» disabled until the draft changes', async () => {
    const wrapper = mountPage();
    await flushPromises();

    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();

    await wrapper
      .find('input[data-test="agent-name-input"]')
      .setValue('Врач-консультант');
    expect(saveButton(wrapper).attributes('disabled')).toBeUndefined();
  });

  it('saves only the changed fields and becomes clean again', async () => {
    const wrapper = mountPage();
    await flushPromises();

    await wrapper
      .find('input[data-test="agent-name-input"]')
      .setValue('Врач-консультант');
    await saveButton(wrapper).trigger('click');
    await flushPromises();

    const updates = dispatchMock.mock.calls.filter(
      ([action]) => action === 'captainAssistants/update'
    );
    expect(updates).toEqual([
      ['captainAssistants/update', { id: 12, name: 'Врач-консультант' }],
    ]);
    expect(useAlertMock).toHaveBeenCalledWith('CAPTAIN.AGENT_PAGE.SAVED');
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();
  });

  it('sends the model settings as one config group with supported parameters', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const draft = instructionTab(wrapper).props('draft');
    instructionTab(wrapper).vm.$emit('update:draft', {
      ...draft,
      model: 'smart-model',
      temperature: 0.5,
    });
    await nextTick();
    await saveButton(wrapper).trigger('click');
    await flushPromises();

    expect(dispatchMock).toHaveBeenCalledWith('captainAssistants/update', {
      id: 12,
      config: {
        model: 'smart-model',
        thinking_effort: 'low',
        temperature: 0.5,
      },
    });
  });

  it('blocks saving an invalid draft and shows why', async () => {
    const wrapper = mountPage();
    await flushPromises();

    await wrapper.find('input[data-test="agent-name-input"]').setValue('  ');
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain('CAPTAIN.AGENT_PAGE.NAME_REQUIRED');

    await wrapper.find('input[data-test="agent-name-input"]').setValue('Врач');
    const draft = instructionTab(wrapper).props('draft');
    instructionTab(wrapper).vm.$emit('update:draft', {
      ...draft,
      instruction: '   ',
    });
    await nextTick();
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();

    await saveButton(wrapper).trigger('click');
    await flushPromises();
    expect(dispatchMock).not.toHaveBeenCalledWith(
      'captainAssistants/update',
      expect.anything()
    );
  });

  it('switches tabs through the tab query parameter', async () => {
    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.find('[data-stub="AgentCheckTab"]').exists()).toBe(false);

    await wrapper.find('button[data-tab="check"]').trigger('click');
    expect(routerReplaceMock).toHaveBeenLastCalledWith({
      name: 'captain_agent_show',
      params: { accountId: '3', assistantId: '12' },
      query: { tab: 'check' },
    });

    route.query = { tab: 'check' };
    await nextTick();
    const checkTab = wrapper.find('[data-stub="AgentCheckTab"]');
    expect(checkTab.exists()).toBe(true);
    expect(checkTab.attributes('style') || '').not.toContain('display: none');
    // The instruction tab stays mounted (hidden) to keep its state.
    expect(
      wrapper.find('[data-stub="AgentInstructionTab"]').attributes('style')
    ).toContain('display: none');

    await wrapper.find('button[data-tab="instruction"]').trigger('click');
    expect(routerReplaceMock).toHaveBeenLastCalledWith({
      name: 'captain_agent_show',
      params: { accountId: '3', assistantId: '12' },
      query: {},
    });
  });

  it('opens the check tab from the header button', async () => {
    const wrapper = mountPage();
    await flushPromises();

    await wrapper.find('[data-test="agent-check"]').trigger('click');
    expect(routerReplaceMock).toHaveBeenLastCalledWith(
      expect.objectContaining({ query: { tab: 'check' } })
    );
  });

  it('asks before leaving with unsaved changes but not when switching tabs', async () => {
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
    const wrapper = mountPage();
    await flushPromises();

    expect(leaveGuards[0]()).toBe(true);

    await wrapper
      .find('input[data-test="agent-name-input"]')
      .setValue('Врач-консультант');

    const from = { params: { assistantId: '12' }, query: {} };
    const sameAgentTab = {
      params: { assistantId: '12' },
      query: { tab: 'check' },
    };
    const otherAgent = { params: { assistantId: '13' }, query: {} };
    expect(updateGuards[0](sameAgentTab, from)).toBe(true);
    expect(confirmSpy).not.toHaveBeenCalled();

    expect(updateGuards[0](otherAgent, from)).toBe(false);
    expect(leaveGuards[0]()).toBe(false);
    expect(confirmSpy).toHaveBeenCalledWith('CAPTAIN.AGENT_PAGE.LEAVE_CONFIRM');
    confirmSpy.mockRestore();
  });

  it('is read-only for non-administrators', async () => {
    policy.isAdmin = false;
    const wrapper = mountPage();
    await flushPromises();

    expect(saveButton(wrapper).exists()).toBe(false);
    expect(wrapper.find('input[data-test="agent-name-input"]').exists()).toBe(
      false
    );
    expect(wrapper.text()).toContain('Администратор');
    expect(matrixStore.fetch).not.toHaveBeenCalled();
  });
});
