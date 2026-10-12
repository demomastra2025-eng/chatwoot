/* eslint-disable vue/one-component-per-file */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h, reactive } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';

const testState = vi.hoisted(() => ({
  getMatrix: vi.fn(),
  updateMatrix: vi.fn(),
  useAlert: vi.fn(),
  isAdmin: true,
  leaveGuard: null,
}));

const route = reactive({ params: { accountId: '1' } });

const matrixPayload = () => ({
  default_main_assistant_id: 12,
  channels: [
    {
      inbox_id: 5,
      name: 'WhatsApp',
      channel_type: 'Channel::Whatsapp',
      ai_enabled: true,
      main_assistant_id: 12,
      assistant_ids: [12, 15],
      auto_reply_mode: 'always',
    },
    {
      inbox_id: 6,
      name: 'Telegram',
      channel_type: 'Channel::Telegram',
      ai_enabled: false,
      main_assistant_id: null,
      assistant_ids: [12],
      auto_reply_mode: 'working_hours',
    },
    {
      inbox_id: 9,
      name: 'Calls',
      channel_type: 'Channel::Voice',
      ai_enabled: true,
      main_assistant_id: 12,
      assistant_ids: [12],
      auto_reply_mode: 'always',
    },
  ],
  assistants: [
    {
      id: 12,
      name: 'Администратор',
      avatar_url: '',
      active: true,
      channel_scope: 'all',
      inbox_ids: [],
    },
    {
      id: 15,
      name: 'Продажи',
      avatar_url: '',
      active: true,
      channel_scope: 'selected',
      inbox_ids: [5],
    },
    {
      id: 20,
      name: 'Архив',
      avatar_url: '',
      active: false,
      channel_scope: 'selected',
      inbox_ids: [],
    },
  ],
});

const PageLayoutStub = defineComponent({
  name: 'PageLayout',
  props: {
    buttonLabel: { type: String, default: '' },
    buttonDisabled: { type: Boolean, default: false },
    isFetching: { type: Boolean, default: false },
  },
  emits: ['click'],
  setup(props, { emit, slots }) {
    return () =>
      h('div', [
        h(
          'button',
          {
            'data-testid': 'page-save',
            disabled: props.buttonDisabled,
            onClick: () => emit('click'),
          },
          props.buttonLabel
        ),
        props.isFetching ? null : slots.body?.(),
      ]);
  },
});

const ButtonStub = defineComponent({
  name: 'NextButton',
  inheritAttrs: false,
  props: {
    label: { type: [String, Number], default: '' },
    icon: { type: String, default: '' },
    disabled: { type: Boolean, default: false },
  },
  emits: ['click'],
  setup(props, { attrs, emit, slots }) {
    return () =>
      h(
        'button',
        {
          ...attrs,
          'data-icon': props.icon,
          disabled: props.disabled,
          onClick: () => emit('click'),
        },
        slots.default?.() || props.label
      );
  },
});

const toggleStub = name =>
  defineComponent({
    name,
    inheritAttrs: false,
    props: {
      modelValue: { type: Boolean, default: false },
      disabled: { type: Boolean, default: false },
    },
    emits: ['update:modelValue'],
    setup(props, { attrs, emit }) {
      return () =>
        h('input', {
          ...attrs,
          type: 'checkbox',
          checked: props.modelValue,
          disabled: props.disabled,
          onChange: event => emit('update:modelValue', event.target.checked),
        });
    },
  });

const selectStub = name =>
  defineComponent({
    name,
    inheritAttrs: false,
    props: {
      modelValue: { type: [String, Number], default: '' },
      options: { type: Array, default: () => [] },
      disabled: { type: Boolean, default: false },
    },
    emits: ['update:modelValue'],
    setup(props, { attrs, emit }) {
      return () =>
        h(
          'select',
          {
            ...attrs,
            value: props.modelValue,
            disabled: props.disabled,
            onChange: event => emit('update:modelValue', event.target.value),
          },
          [
            h('option', { value: '' }, ''),
            ...props.options.map(option =>
              h('option', { value: option.value }, option.label)
            ),
          ]
        );
    },
  });

const DropdownMenuStub = defineComponent({
  name: 'DropdownMenu',
  props: { menuItems: { type: Array, default: () => [] } },
  emits: ['action'],
  setup(props, { emit }) {
    return () =>
      h(
        'div',
        { 'data-testid': 'scope-menu' },
        props.menuItems.map(item =>
          h(
            'button',
            {
              'data-testid': `scope-option-${item.value}`,
              onClick: () => emit('action', item),
            },
            item.label
          )
        )
      );
  },
});

const spanStub = name =>
  defineComponent({ name, setup: () => () => h('span') });

const passthroughStub = name =>
  defineComponent({
    name,
    setup:
      (_, { slots }) =>
      () =>
        h('div', slots.default?.()),
  });

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => route,
  onBeforeRouteLeave: guard => {
    testState.leaveGuard = guard;
  },
  onBeforeRouteUpdate: () => {},
}));

vi.mock('@vueuse/components', () => ({
  OnClickOutside: passthroughStub('OnClickOutside'),
}));

vi.mock('dashboard/api/captain/channelMatrix', () => ({
  default: {
    get: (...args) => testState.getMatrix(...args),
    update: (...args) => testState.updateMatrix(...args),
    accountIdFromRoute: '1',
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => testState.useAlert(...args),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => computed(() => []),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => testState.isAdmin }),
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: PageLayoutStub,
}));
vi.mock('dashboard/components-next/captain/pageComponents/Paywall.vue', () => ({
  default: spanStub('CaptainPaywall'),
}));
vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: ButtonStub,
}));
vi.mock('dashboard/components-next/checkbox/Checkbox.vue', () => ({
  default: toggleStub('Checkbox'),
}));
vi.mock('dashboard/components-next/switch/Switch.vue', () => ({
  default: toggleStub('Switch'),
}));
vi.mock('dashboard/components-next/select/Select.vue', () => ({
  default: selectStub('Select'),
}));
vi.mock('dashboard/components-next/combobox/ComboBox.vue', () => ({
  default: selectStub('ComboBox'),
}));
vi.mock('dashboard/components-next/dropdown-menu/DropdownMenu.vue', () => ({
  default: DropdownMenuStub,
}));
vi.mock('dashboard/components-next/avatar/Avatar.vue', () => ({
  default: spanStub('Avatar'),
}));
vi.mock('dashboard/components-next/icon/ChannelIcon.vue', () => ({
  default: spanStub('ChannelIcon'),
}));

const { default: ChannelsIndex } = await import('./Index.vue');

const mountPage = async () => {
  const wrapper = mount(ChannelsIndex, {
    global: { stubs: { teleport: true } },
  });
  await flushPromises();
  return wrapper;
};

const table = wrapper => wrapper.get('[data-testid="matrix-table"]');
const saveButton = wrapper => wrapper.get('[data-testid="page-save"]');

const clickSave = async wrapper => {
  await saveButton(wrapper).trigger('click');
  await flushPromises();
};

const agentSelector = id => `[data-testid="matrix-agent-${id}"]`;

const chooseScope = async (wrapper, assistantId, scope) => {
  await table(wrapper)
    .get(agentSelector(assistantId))
    .get('[data-testid="matrix-scope-trigger"]')
    .trigger('click');
  await wrapper.get(`[data-testid="scope-option-${scope}"]`).trigger('click');
};

describe('Captain channels matrix page', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    testState.getMatrix.mockReset();
    testState.getMatrix.mockResolvedValue({ data: matrixPayload() });
    testState.updateMatrix.mockReset();
    testState.updateMatrix.mockImplementation(() =>
      Promise.resolve({ data: matrixPayload() })
    );
    testState.useAlert.mockReset();
    testState.isAdmin = true;
    testState.leaveGuard = null;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('renders text channels only and the voice note', async () => {
    const wrapper = await mountPage();

    expect(testState.getMatrix).toHaveBeenCalledTimes(1);
    expect(table(wrapper).find('[data-testid="matrix-row-5"]').exists()).toBe(
      true
    );
    expect(table(wrapper).find('[data-testid="matrix-row-6"]').exists()).toBe(
      true
    );
    expect(table(wrapper).find('[data-testid="matrix-row-9"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-testid="matrix-voice-note"]').exists()).toBe(
      false
    );
    expect(saveButton(wrapper).element.disabled).toBe(true);
    // Design rule: no framed block nested inside the matrix block.
    expect(table(wrapper).findAll('.rounded-xl')).toHaveLength(0);
  });

  it('renders the main star only on checked cells', async () => {
    const wrapper = await mountPage();
    const star = id => table(wrapper).find(`[data-testid="matrix-star-${id}"]`);

    expect(star('5-12').attributes('data-icon')).toBe('i-ri-star-fill');
    expect(star('5-15').attributes('data-icon')).toBe('i-ri-star-line');
    expect(star('6-15').exists()).toBe(false);
    expect(star('5-20').exists()).toBe(false);

    await table(wrapper).get('[data-testid="matrix-cell-6-15"]').setValue(true);
    expect(star('6-15').exists()).toBe(true);
    expect(star('6-15').element.disabled).toBe(false);

    await table(wrapper).get('[data-testid="matrix-cell-6-20"]').setValue(true);
    expect(star('6-20').exists()).toBe(true);
    expect(star('6-20').element.disabled).toBe(true);
  });

  it('switches a column scope from the header menu', async () => {
    const wrapper = await mountPage();
    const header = id => table(wrapper).get(agentSelector(id));

    expect(header(12).text()).toContain('CAPTAIN.CHANNEL_MATRIX.SCOPE_ALL');
    await chooseScope(wrapper, 12, 'selected');
    expect(header(12).text()).toContain(
      'CAPTAIN.CHANNEL_MATRIX.SCOPE_SELECTED'
    );

    await chooseScope(wrapper, 15, 'all');
    expect(header(15).text()).toContain('CAPTAIN.CHANNEL_MATRIX.SCOPE_ALL');
    expect(
      table(wrapper).get('[data-testid="matrix-cell-6-15"]').element.checked
    ).toBe(true);

    await clickSave(wrapper);

    expect(testState.updateMatrix).toHaveBeenCalledTimes(1);
    expect(testState.updateMatrix).toHaveBeenCalledWith({
      assistants: [
        { id: 12, channel_scope: 'selected', inbox_ids: [5, 6] },
        { id: 15, channel_scope: 'all', inbox_ids: [] },
      ],
    });
  });

  it('unchecking a cell of an «all channels» agent converts it and clears its star', async () => {
    const wrapper = await mountPage();

    await table(wrapper)
      .get('[data-testid="matrix-cell-5-12"]')
      .setValue(false);

    expect(
      table(wrapper).find('[data-testid="matrix-star-5-12"]').exists()
    ).toBe(false);
    expect(
      table(wrapper).get('[data-testid="matrix-agent-12"]').text()
    ).toContain('CAPTAIN.CHANNEL_MATRIX.SCOPE_SELECTED');
    expect(
      table(wrapper).find('[data-testid="matrix-main-hint-5"]').exists()
    ).toBe(true);

    await table(wrapper)
      .get('[data-testid="matrix-star-5-15"]')
      .trigger('click');
    expect(
      table(wrapper).find('[data-testid="matrix-main-hint-5"]').exists()
    ).toBe(false);

    await clickSave(wrapper);

    expect(testState.updateMatrix).toHaveBeenCalledTimes(1);
    expect(testState.updateMatrix).toHaveBeenCalledWith({
      channels: [
        {
          inbox_id: 5,
          ai_enabled: true,
          main_assistant_id: 15,
          auto_reply_mode: 'always',
        },
      ],
      assistants: [{ id: 12, channel_scope: 'selected', inbox_ids: [6] }],
    });
  });

  it('saves one atomic PATCH with the minimal body and resets the draft', async () => {
    const saved = matrixPayload();
    saved.channels[1] = {
      ...saved.channels[1],
      ai_enabled: true,
      main_assistant_id: 12,
    };
    testState.updateMatrix.mockResolvedValue({ data: saved });
    const wrapper = await mountPage();

    await table(wrapper).get('[data-testid="matrix-ai-6"]').setValue(true);
    expect(table(wrapper).find('[data-testid="matrix-mode-6"]').exists()).toBe(
      true
    );
    expect(saveButton(wrapper).element.disabled).toBe(false);

    await clickSave(wrapper);

    expect(testState.updateMatrix).toHaveBeenCalledTimes(1);
    expect(testState.updateMatrix).toHaveBeenCalledWith({
      channels: [
        {
          inbox_id: 6,
          ai_enabled: true,
          main_assistant_id: 12,
          auto_reply_mode: 'working_hours',
        },
      ],
    });
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.CHANNEL_MATRIX.SAVED'
    );
    expect(saveButton(wrapper).element.disabled).toBe(true);
  });

  it('keeps the draft on 422 and shows row errors and general errors', async () => {
    testState.updateMatrix.mockRejectedValue({
      response: {
        status: 422,
        data: {
          errors: [
            {
              inbox_id: 5,
              assistant_id: null,
              code: 'MAIN_AGENT_INACTIVE',
              message: 'Row five main agent is off',
            },
            {
              inbox_id: null,
              assistant_id: 12,
              code: 'INVALID_DEFAULT',
              message: 'Default agent is invalid',
            },
          ],
        },
      },
    });
    const wrapper = await mountPage();

    await table(wrapper)
      .get('[data-testid="matrix-mode-5"]')
      .setValue('outside_working_hours');
    await clickSave(wrapper);

    expect(testState.updateMatrix).toHaveBeenCalledTimes(1);
    expect(
      table(wrapper).get('[data-testid="matrix-row-error-5"]').text()
    ).toBe('Row five main agent is off');
    expect(wrapper.get('[data-testid="matrix-card-error-5"]').text()).toBe(
      'Row five main agent is off'
    );
    expect(
      wrapper.get('[data-testid="matrix-general-errors"]').text()
    ).toContain('Default agent is invalid');
    expect(
      table(wrapper).get('[data-testid="matrix-mode-5"]').element.value
    ).toBe('outside_working_hours');
    expect(saveButton(wrapper).element.disabled).toBe(false);
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.CHANNEL_MATRIX.SAVE_ERROR'
    );

    // Editing the row again clears its stale server error.
    await table(wrapper)
      .get('[data-testid="matrix-mode-5"]')
      .setValue('working_hours');
    expect(
      table(wrapper).find('[data-testid="matrix-row-error-5"]').exists()
    ).toBe(false);
  });

  it('renders one mobile card per text channel with agent chips and a main select', async () => {
    const wrapper = await mountPage();
    const cards = wrapper.get('[data-testid="matrix-cards"]');

    expect(cards.find('[data-testid="matrix-card-5"]').exists()).toBe(true);
    expect(cards.find('[data-testid="matrix-card-6"]').exists()).toBe(true);
    expect(cards.find('[data-testid="matrix-card-9"]').exists()).toBe(false);

    const chip = cards.get('[data-testid="matrix-chip-6-15"]');
    expect(chip.attributes('aria-pressed')).toBe('false');
    await chip.trigger('click');
    expect(
      cards.get('[data-testid="matrix-chip-6-15"]').attributes('aria-pressed')
    ).toBe('true');

    await cards.get('[data-testid="matrix-card-main-6"]').setValue('15');
    await clickSave(wrapper);

    expect(testState.updateMatrix).toHaveBeenCalledWith({
      channels: [
        {
          inbox_id: 6,
          ai_enabled: false,
          main_assistant_id: 15,
          auto_reply_mode: 'working_hours',
        },
      ],
      assistants: [{ id: 15, channel_scope: 'selected', inbox_ids: [5, 6] }],
    });
  });

  it('changes the workspace default main agent', async () => {
    const wrapper = await mountPage();

    await wrapper.get('[data-testid="matrix-default-main"]').setValue('15');
    await clickSave(wrapper);

    expect(testState.updateMatrix).toHaveBeenCalledWith({
      default_main_assistant_id: 15,
    });
  });

  it('asks before leaving with unsaved changes', async () => {
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
    const wrapper = await mountPage();

    expect(testState.leaveGuard()).toBe(true);
    expect(confirmSpy).not.toHaveBeenCalled();

    await table(wrapper).get('[data-testid="matrix-ai-6"]').setValue(true);

    expect(testState.leaveGuard()).toBe(false);
    expect(confirmSpy).toHaveBeenCalledWith(
      'CAPTAIN.CHANNEL_MATRIX.LEAVE_CONFIRM'
    );
  });

  it('shows a load error and no matrix when the request fails', async () => {
    testState.getMatrix.mockRejectedValue({ response: { status: 403 } });
    const wrapper = await mountPage();

    expect(wrapper.find('[data-testid="matrix-load-error"]').exists()).toBe(
      true
    );
    expect(wrapper.find('[data-testid="matrix-table"]').exists()).toBe(false);
  });

  it('does not request the admin-only matrix for other roles', async () => {
    testState.isAdmin = false;
    await mountPage();

    expect(testState.getMatrix).not.toHaveBeenCalled();
  });
});
