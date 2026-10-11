/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h, reactive } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import assistantStore from 'dashboard/store/captain/assistant';

const VOICE_CHANNEL_TYPE = 'Channel::Voice';

const mockState = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlert: vi.fn(),
  routerPush: vi.fn(),
  isAdmin: true,
  routeParams: { accountId: '1', inboxId: '4593' },
  assistantFlags: { fetchingList: false },
  inbox: {},
  assistants: [],
  matrixStore: null,
}));

const voiceInbox = () => ({
  id: 4593,
  name: '+771****5175',
  channel_type: VOICE_CHANNEL_TYPE,
  captain_assistant: null,
  captain_auto_reply_mode: null,
  captain_reply_to_open_conversations: false,
});

const textInbox = () => ({
  id: 4593,
  name: 'WhatsApp clinic',
  channel_type: 'Channel::Whatsapp',
  captain_assistant: { id: 101, name: 'Sales assistant' },
  captain_auto_reply_mode: 'always',
});

const defaultAssistants = () => [
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

const buildMatrixStore = () =>
  reactive({
    getChannels: [
      {
        inbox_id: 4593,
        name: 'WhatsApp clinic',
        channel_type: 'Channel::Whatsapp',
        ai_enabled: true,
        main_assistant_id: 101,
        assistant_ids: [101, 102],
        auto_reply_mode: 'always',
      },
    ],
    getAssistants: [
      { id: 101, name: 'Sales assistant', avatar_url: '', active: true },
      { id: 102, name: 'Support assistant', avatar_url: '', active: true },
    ],
    getUIFlags: { isFetching: false, isSaving: false, fetchError: false },
    fetch: vi.fn(() => Promise.resolve(null)),
  });

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

const StatusDotStub = defineComponent({
  name: 'DsStatusDot',
  props: {
    status: { type: String, default: 'neutral' },
    label: { type: String, default: '' },
  },
  setup(props, { attrs }) {
    return () =>
      h('span', { ...attrs, 'data-status': props.status }, props.label);
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
  useRouter: () => ({ push: mockState.routerPush }),
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
    te: () => true,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockState.useAlert(...args),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => mockState.isAdmin }),
}));

vi.mock('dashboard/store/captain/channelMatrix', () => ({
  useCaptainChannelMatrixStore: () => mockState.matrixStore,
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
      // The real getter of the assistant store decides what the picker sees.
      return computed(() =>
        assistantStore.getters.getRecords({ records: mockState.assistants })
      );
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
vi.mock('dashboard/components-next/ds/DsStatusDot.vue', () => ({
  default: StatusDotStub,
}));
vi.mock('dashboard/components/policy.vue', () => ({
  default: passthroughStub('Policy'),
}));
vi.mock('dashboard/components-next/select/Select.vue', () => ({
  default: SelectInputStub,
}));
vi.mock('dashboard/components-next/spinner/Spinner.vue', () => ({
  default: defineComponent({
    name: 'Spinner',
    template: '<span data-testid="spinner" />',
  }),
}));

const { default: BotConfiguration } = await import('./BotConfiguration.vue');

const buildWrapper = props => mount(BotConfiguration, { props });

describe('Inbox BotConfiguration', () => {
  beforeEach(() => {
    mockState.dispatch.mockReset();
    mockState.dispatch.mockResolvedValue({});
    mockState.useAlert.mockReset();
    mockState.routerPush.mockReset();
    mockState.isAdmin = true;
    mockState.routeParams = { accountId: '1', inboxId: '4593' };
    mockState.assistantFlags = { fetchingList: false };
    mockState.inbox = voiceInbox();
    mockState.assistants = defaultAssistants();
    mockState.matrixStore = buildMatrixStore();
  });

  describe('text inbox: read-only summary of the «Каналы» matrix', () => {
    beforeEach(() => {
      mockState.inbox = textInbox();
    });

    it('shows AI state, main agent and other agents from the matrix for admins', async () => {
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      expect(mockState.matrixStore.fetch).toHaveBeenCalledTimes(1);
      expect(mockState.dispatch).not.toHaveBeenCalledWith(
        'captainAssistants/get'
      );
      expect(
        wrapper.find('[data-testid="captain-inbox-summary"]').exists()
      ).toBe(true);
      expect(
        wrapper.find('[data-testid="captain-inbox-assistant"]').exists()
      ).toBe(false);
      expect(wrapper.find('[data-testid="captain-inbox-save"]').exists()).toBe(
        false
      );

      const status = wrapper.get('[data-testid="captain-inbox-ai-status"]');
      expect(status.attributes('data-status')).toBe('good');
      expect(status.text()).toBe('CAPTAIN.CHANNEL_MATRIX.BOT_CONFIG.AI_ON');
      expect(
        wrapper.get('[data-testid="captain-inbox-main-agent"]').text()
      ).toContain('Sales assistant');
      const others = wrapper.get('[data-testid="captain-inbox-other-agents"]');
      expect(others.text()).toContain('Support assistant');
      expect(others.text()).not.toContain('Sales assistant');
    });

    it('shows AI off when the matrix row has AI disabled', async () => {
      mockState.matrixStore.getChannels[0].ai_enabled = false;
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      const status = wrapper.get('[data-testid="captain-inbox-ai-status"]');
      expect(status.attributes('data-status')).toBe('neutral');
      expect(status.text()).toBe('CAPTAIN.CHANNEL_MATRIX.BOT_CONFIG.AI_OFF');
    });

    it('links admins to the channel matrix page', async () => {
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      await wrapper
        .get('[data-testid="captain-inbox-open-matrix"]')
        .trigger('click');

      expect(mockState.routerPush).toHaveBeenCalledWith({
        name: 'captain_channels_index',
        params: { accountId: '1' },
      });
    });

    it('falls back to the inbox payload for agents without matrix access', async () => {
      mockState.isAdmin = false;
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      expect(mockState.matrixStore.fetch).not.toHaveBeenCalled();
      expect(
        wrapper.get('[data-testid="captain-inbox-main-agent"]').text()
      ).toContain('Sales assistant');
      expect(
        wrapper.get('[data-testid="captain-inbox-ai-status"]').text()
      ).toBe('CAPTAIN.CHANNEL_MATRIX.BOT_CONFIG.AI_ON');
      expect(
        wrapper.find('[data-testid="captain-inbox-other-agents"]').exists()
      ).toBe(false);
      expect(
        wrapper.find('[data-testid="captain-inbox-open-matrix"]').exists()
      ).toBe(false);
    });

    it('shows no main agent and AI off for an inbox without a captain agent', async () => {
      mockState.isAdmin = false;
      mockState.inbox = { ...textInbox(), captain_assistant: null };
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      expect(
        wrapper.get('[data-testid="captain-inbox-main-agent"]').text()
      ).toContain('CAPTAIN.CHANNEL_MATRIX.BOT_CONFIG.MAIN_NONE');
      expect(
        wrapper.get('[data-testid="captain-inbox-ai-status"]').text()
      ).toBe('CAPTAIN.CHANNEL_MATRIX.BOT_CONFIG.AI_OFF');
    });
  });

  describe('voice inbox: the per-inbox editor stays', () => {
    it('renders a profile-style assistant dropdown and response mode', async () => {
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      expect(wrapper.text()).toContain('+771****5175');
      expect(mockState.matrixStore.fetch).not.toHaveBeenCalled();
      expect(
        wrapper.find('[data-testid="captain-inbox-summary"]').exists()
      ).toBe(false);
      expect(
        wrapper.find('[data-testid="captain-inbox-assistant"]').exists()
      ).toBe(true);
      expect(
        wrapper.find('[data-testid="captain-inbox-auto-reply-mode"]').exists()
      ).toBe(true);
      expect(
        wrapper
          .find('[data-testid="captain-inbox-reply-to-open-conversations"]')
          .exists()
      ).toBe(false);
      expect(
        wrapper
          .find(
            '[data-testid="captain-inbox-auto-reply-mode"] option[value="never"]'
          )
          .exists()
      ).toBe(false);

      await wrapper
        .get('[data-testid="captain-inbox-assistant"]')
        .trigger('click');

      expect(wrapper.text()).toContain('Sales assistant');
      expect(wrapper.text()).toContain('Support assistant');
      expect(wrapper.find('[data-testid="avatar"]').exists()).toBe(true);
      expect(wrapper.text()).toContain(
        'CAPTAIN.INBOXES.CHANNEL_SETTINGS.TITLE'
      );
      expect(mockState.dispatch).toHaveBeenCalledWith('captainAssistants/get');
    });

    it('keeps the main agent and mode as a local draft until Save', async () => {
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      await wrapper
        .get('[data-testid="captain-inbox-assistant"]')
        .trigger('click');
      await wrapper
        .get('[data-testid="captain-inbox-assistant-option-101"]')
        .trigger('click');
      await flushPromises();
      expect(mockState.dispatch).not.toHaveBeenCalledWith(
        'captainInboxes/create',
        expect.anything()
      );
      await wrapper
        .get('[data-testid="captain-inbox-auto-reply-mode"]')
        .setValue('working_hours');
      expect(mockState.dispatch).not.toHaveBeenCalledWith(
        'captainInboxes/create',
        expect.anything()
      );
      await wrapper.get('[data-testid="captain-inbox-save"]').trigger('click');
      await flushPromises();
      expect(mockState.dispatch).toHaveBeenCalledWith('captainInboxes/create', {
        assistantId: 101,
        inboxId: 4593,
        autoReplyMode: 'working_hours',
      });
      expect(mockState.dispatch).toHaveBeenCalledWith('inboxes/get');
      expect(mockState.useAlert).toHaveBeenCalledWith(
        'CAPTAIN.INBOXES.CHANNEL_SETTINGS.SAVE_SUCCESS'
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
      expect(mockState.dispatch).not.toHaveBeenCalledWith(
        'captainInboxes/create',
        expect.anything()
      );
      await wrapper.get('[data-testid="captain-inbox-save"]').trigger('click');
      await flushPromises();
      expect(mockState.dispatch).toHaveBeenCalledWith('captainInboxes/create', {
        assistantId: 101,
        inboxId: 4593,
        autoReplyMode: 'outside_working_hours',
      });
      expect(mockState.useAlert).toHaveBeenCalledWith(
        'CAPTAIN.INBOXES.CHANNEL_SETTINGS.SAVE_SUCCESS'
      );
    });

    it('cancels a local draft and resets it when opening another voice inbox', async () => {
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();
      await wrapper
        .get('[data-testid="captain-inbox-assistant-option-101"]')
        .trigger('click');
      expect(
        wrapper.get('[data-testid="captain-inbox-save"]').element.disabled
      ).toBe(false);
      await wrapper
        .get('[data-testid="captain-inbox-cancel"]')
        .trigger('click');
      expect(
        wrapper.get('[data-testid="captain-inbox-save"]').element.disabled
      ).toBe(true);
      expect(
        wrapper.get('[data-testid="captain-inbox-assistant"]').text()
      ).toContain('CAPTAIN.INBOXES.CHANNEL_SETTINGS.ASSISTANT.NO_AGENT');
      await wrapper
        .get('[data-testid="captain-inbox-assistant-option-101"]')
        .trigger('click');
      await wrapper.setProps({
        inbox: {
          id: 77,
          name: 'Other inbox',
          channel_type: VOICE_CHANNEL_TYPE,
          captain_assistant: { id: 102, name: 'Support assistant' },
          captain_auto_reply_mode: 'working_hours',
        },
      });
      expect(
        wrapper.get('[data-testid="captain-inbox-assistant"]').text()
      ).toContain('Support assistant');
      expect(
        wrapper.get('[data-testid="captain-inbox-save"]').element.disabled
      ).toBe(true);
      expect(mockState.dispatch).not.toHaveBeenCalledWith(
        'captainInboxes/create',
        expect.anything()
      );
    });

    it('does not offer a disabled main agent', async () => {
      mockState.assistants[0].active = false;
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();
      expect(
        wrapper
          .find('[data-testid="captain-inbox-assistant-option-101"]')
          .exists()
      ).toBe(false);
    });

    it('does not offer open conversation replies even for a legacy inbox with them enabled', async () => {
      mockState.inbox = {
        ...mockState.inbox,
        captain_assistant: { id: 101, name: 'Sales assistant' },
        captain_auto_reply_mode: 'outside_working_hours',
        captain_reply_to_open_conversations: true,
      };

      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      expect(
        wrapper
          .find('[data-testid="captain-inbox-reply-to-open-conversations"]')
          .exists()
      ).toBe(false);
    });

    it('lists only AI agents: internal assistants are hidden by the assistant store', async () => {
      mockState.assistants = [
        ...mockState.assistants,
        {
          id: 103,
          name: 'Team helper',
          description: 'Works inside the team',
          usage_mode: 'internal_assistant',
        },
      ];
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      await wrapper
        .get('[data-testid="captain-inbox-assistant"]')
        .trigger('click');

      expect(wrapper.text()).toContain('Sales assistant');
      expect(wrapper.text()).toContain('Support assistant');
      expect(wrapper.text()).not.toContain('Team helper');
      expect(wrapper.text()).not.toContain('USAGE_MODE');
      expect(
        wrapper
          .find('[data-testid="captain-inbox-assistant-option-103"]')
          .exists()
      ).toBe(false);
    });

    it('offers no assistant choice when the account only has an internal assistant', async () => {
      mockState.assistants = [
        {
          id: 103,
          name: 'Team helper',
          description: 'Works inside the team',
          usage_mode: 'internal_assistant',
        },
      ];
      const wrapper = buildWrapper({ inbox: mockState.inbox });
      await flushPromises();

      await wrapper
        .get('[data-testid="captain-inbox-assistant"]')
        .trigger('click');

      expect(wrapper.text()).not.toContain('Team helper');
      expect(
        wrapper
          .find('[data-testid="captain-inbox-assistant-option-103"]')
          .exists()
      ).toBe(false);
    });
  });
});
