/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const mockState = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlert: vi.fn(),
  routeParams: { inboxId: '4593' },
  assistantFlags: { fetchingList: false },
  inbox: {
    id: 4593,
    name: '+771****5175',
    captain_assistant: null,
    captain_auto_reply_mode: null,
  },
  assistants: [
    {
      id: 101,
      name: 'Sales assistant',
      description: 'Handles sales messages',
      usage_mode: 'external_agent',
    },
    {
      id: 102,
      name: 'Support assistant',
      description: 'Handles support messages',
      usage_mode: 'external_agent',
    },
  ],
}));

const passthroughStub = name =>
  defineComponent({
    name,
    props: {
      title: { type: String, default: '' },
      label: { type: String, default: '' },
      helpText: { type: String, default: '' },
    },
    setup(props, { slots }) {
      return () =>
        h('div', [
          props.title ? h('h2', props.title) : null,
          props.label ? h('label', props.label) : null,
          props.helpText ? h('p', props.helpText) : null,
          slots.default?.(),
        ]);
    },
  });

const SelectInputStub = defineComponent({
  name: 'SelectInput',
  props: {
    modelValue: { type: [String, Number], default: '' },
    disabled: { type: Boolean, default: false },
    options: { type: Array, default: () => [] },
  },
  emits: ['change', 'update:modelValue'],
  setup(props, { emit, attrs }) {
    return () =>
      h(
        'select',
        {
          id: attrs.id,
          'data-testid': attrs.id,
          value: props.modelValue,
          disabled: props.disabled,
          onChange: event => {
            emit('update:modelValue', event.target.value);
            emit('change', event);
          },
        },
        props.options.map(option =>
          h('option', { value: option.value }, option.label)
        )
      );
  },
});

const ButtonStub = defineComponent({
  name: 'NextButton',
  props: {
    label: { type: [String, Number], default: '' },
    disabled: { type: Boolean, default: false },
  },
  setup(props, { attrs, slots }) {
    return () =>
      h(
        'button',
        { ...attrs, disabled: props.disabled || attrs.disabled },
        slots.default?.() || props.label
      );
  },
});

const AvatarStub = defineComponent({
  name: 'Avatar',
  setup() {
    return () => h('span', { 'data-testid': 'avatar' });
  },
});

const OnClickOutsideStub = defineComponent({
  name: 'OnClickOutside',
  setup(_, { slots }) {
    return () => h('div', slots.default?.());
  },
});

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: mockState.routeParams }),
}));

vi.mock('@vueuse/components', () => ({
  OnClickOutside: OnClickOutsideStub,
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      params.inboxName || params.assistantName
        ? `${key}:${params.inboxName || params.assistantName}`
        : key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockState.useAlert(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: mockState.dispatch,
    getters: {
      'inboxes/getInbox': inboxId =>
        Number(inboxId) === mockState.inbox.id ? mockState.inbox : {},
    },
  }),
  useMapGetter: key => {
    if (key === 'captainAssistants/getRecords') {
      return computed(() => mockState.assistants);
    }
    if (key === 'captainAssistants/getUIFlags') {
      return computed(() => mockState.assistantFlags);
    }

    return computed(() => ({}));
  },
}));

vi.mock('dashboard/components-next/icon/Icon.vue', () => ({
  default: defineComponent({ name: 'Icon', template: '<span />' }),
}));
vi.mock('dashboard/components-next/avatar/Avatar.vue', () => ({
  default: AvatarStub,
}));
vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: ButtonStub,
}));
vi.mock('dashboard/components/policy.vue', () => ({
  default: passthroughStub('Policy'),
}));
vi.mock('dashboard/components-next/select/Select.vue', () => ({
  default: SelectInputStub,
}));
vi.mock('dashboard/components-next/Settings/SettingsAccordion.vue', () => ({
  default: passthroughStub('SettingsAccordion'),
}));
vi.mock('dashboard/components-next/Settings/SettingsFieldSection.vue', () => ({
  default: passthroughStub('SettingsFieldSection'),
}));
vi.mock('dashboard/components-next/spinner/Spinner.vue', () => ({
  default: defineComponent({
    name: 'Spinner',
    template: '<span data-testid="spinner" />',
  }),
}));

const { default: BotConfiguration } = await import('./BotConfiguration.vue');

const buildWrapper = props => mount(BotConfiguration, { props });

describe('Inbox BotConfiguration Captain settings', () => {
  beforeEach(() => {
    mockState.dispatch.mockReset();
    mockState.dispatch.mockResolvedValue({});
    mockState.useAlert.mockReset();
    mockState.routeParams = { inboxId: '4593' };
    mockState.assistantFlags = { fetchingList: false };
    mockState.inbox = {
      id: 4593,
      name: '+771****5175',
      captain_assistant: null,
      captain_auto_reply_mode: null,
    };
    mockState.assistants = [
      {
        id: 101,
        name: 'Sales assistant',
        description: 'Handles sales messages',
        usage_mode: 'external_agent',
      },
      {
        id: 102,
        name: 'Support assistant',
        description: 'Handles support messages',
        usage_mode: 'external_agent',
      },
    ];
  });

  it('renders a native settings form with assistant list and response mode', async () => {
    const wrapper = buildWrapper({ inbox: mockState.inbox });
    await flushPromises();

    expect(wrapper.text()).toContain('+771****5175');
    expect(
      wrapper.find('[data-testid="captain-inbox-assistant"]').exists()
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="captain-inbox-auto-reply-mode"]').exists()
    ).toBe(true);

    expect(wrapper.text()).toContain('Sales assistant');
    expect(wrapper.text()).toContain('Support assistant');
    expect(wrapper.text()).toContain('CAPTAIN.INBOXES.CHANNEL_SETTINGS.TITLE');
    expect(mockState.dispatch).toHaveBeenCalledWith('captainAssistants/get');
  });

  it('connects the concrete inbox when an assistant is selected', async () => {
    const wrapper = buildWrapper({ inbox: mockState.inbox });
    await flushPromises();

    await wrapper
      .get('[data-testid="captain-inbox-assistant"]')
      .setValue('101');
    await flushPromises();

    expect(mockState.dispatch).toHaveBeenCalledWith('captainInboxes/create', {
      assistantId: 101,
      inboxId: 4593,
      autoReplyMode: 'always',
    });
    expect(mockState.dispatch).toHaveBeenCalledWith('inboxes/get');
    expect(mockState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.INBOXES.CREATE.SUCCESS_MESSAGE'
    );
  });

  it('updates the auto-reply mode for the connected assistant', async () => {
    mockState.inbox = {
      ...mockState.inbox,
      captain_assistant: { id: 101, name: 'Sales assistant' },
      captain_auto_reply_mode: 'working_hours',
    };

    const wrapper = buildWrapper({ inbox: mockState.inbox });
    await flushPromises();

    await wrapper
      .get('[data-testid="captain-inbox-auto-reply-mode"]')
      .setValue('outside_working_hours');
    await flushPromises();

    expect(mockState.dispatch).toHaveBeenCalledWith('captainInboxes/create', {
      assistantId: 101,
      inboxId: 4593,
      autoReplyMode: 'outside_working_hours',
    });
    expect(mockState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.INBOXES.AUTO_REPLY_MODE.UPDATE.SUCCESS_MESSAGE'
    );
  });
});
