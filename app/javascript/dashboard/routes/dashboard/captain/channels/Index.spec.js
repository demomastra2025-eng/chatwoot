/* eslint-disable vue/one-component-per-file */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const state = vi.hoisted(() => ({
  fetch: vi.fn(),
  save: vi.fn(),
  alert: vi.fn(),
  matrix: null,
  uiFlags: { fetchError: false },
}));

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => state.alert(...args),
}));
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));
vi.mock('dashboard/store/captain/channelMatrix', () => ({
  useCaptainChannelMatrixStore: () => ({
    get getMatrix() {
      return state.matrix;
    },
    getUIFlags: state.uiFlags,
    fetch: (...args) => state.fetch(...args),
    save: (...args) => state.save(...args),
  }),
}));
vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    props: { buttonDisabled: Boolean },
    emits: ['click'],
    setup(props, { slots, emit }) {
      return () =>
        h('div', [
          h('button', {
            'data-testid': 'save',
            disabled: props.buttonDisabled,
            onClick: () => emit('click'),
          }),
          slots.body?.(),
        ]);
    },
  }),
}));

const { default: ChannelsPage } = await import('./Index.vue');
const agent = (id, active = true) => ({
  id,
  name: `Agent ${id}`,
  active,
  has_card: true,
  avatar_url: null,
});
const payload = (assistants = [agent(12), agent(13)]) => ({
  assistants,
  channels: [
    {
      inbox_id: 5,
      name: 'WhatsApp',
      channel_type: 'Channel::Whatsapp',
      ai_enabled: true,
    },
    {
      inbox_id: 6,
      name: 'Telegram',
      channel_type: 'Channel::Telegram',
      ai_enabled: false,
    },
    {
      inbox_id: 9,
      name: 'Calls',
      channel_type: 'Channel::Voice',
      ai_enabled: true,
    },
  ],
});

const mountPage = async () => {
  const wrapper = mount(ChannelsPage, {
    global: {
      stubs: {
        CaptainPaywall: true,
        Banner: { template: '<div data-testid="banner"><slot /></div>' },
      },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('Captain text channel switches', () => {
  beforeEach(() => {
    state.fetch.mockReset();
    state.save.mockReset();
    state.alert.mockReset();
    state.matrix = payload();
    state.fetch.mockResolvedValue(state.matrix);
    state.save.mockImplementation(async patch => {
      state.matrix = {
        ...state.matrix,
        channels: state.matrix.channels.map(channel => ({
          ...channel,
          ...patch.channels.find(row => row.inbox_id === channel.inbox_id),
        })),
      };
      return { ok: true, matrix: state.matrix };
    });
  });

  it('lists only text channels with icons and one switch each', async () => {
    const wrapper = await mountPage();
    expect(wrapper.text()).toContain('WhatsApp');
    expect(wrapper.text()).toContain('Telegram');
    expect(wrapper.text()).not.toContain('Calls');
    expect(wrapper.findAll('[role="switch"]')).toHaveLength(2);
    expect(wrapper.findAll('[data-testid="channel-icon"]')).toHaveLength(2);
  });

  it('saves only changed channel switches', async () => {
    const wrapper = await mountPage();
    await wrapper.findAll('[role="switch"]')[1].trigger('click');
    await wrapper.find('[data-testid="save"]').trigger('click');
    await flushPromises();
    expect(state.save).toHaveBeenCalledWith({
      channels: [{ inbox_id: 6, ai_enabled: true }],
    });
  });

  it('allows disabling all channels at once', async () => {
    const wrapper = await mountPage();
    await wrapper.find('[data-testid="channels-toggle-all"]').trigger('click');
    await wrapper.find('[data-testid="save"]').trigger('click');
    await flushPromises();
    expect(state.save).toHaveBeenCalledWith({
      channels: [{ inbox_id: 5, ai_enabled: false }],
    });
  });

  it('has no main agent: the switches work with no agent chosen', async () => {
    const wrapper = await mountPage();
    expect(wrapper.text()).not.toContain('CAPTAIN.CHANNEL_MATRIX.MAIN');
    expect(
      wrapper
        .findAll('[role="switch"]')
        .every(input => input.attributes('disabled') === undefined)
    ).toBe(true);
    expect(
      wrapper.find('[data-testid="channels-toggle-all"]').attributes('disabled')
    ).toBeUndefined();
  });

  it('tells that the AI stays silent when no agent is on, and the switches still save', async () => {
    state.matrix = payload([agent(12, false), agent(13, false)]);
    state.fetch.mockResolvedValue(state.matrix);
    const wrapper = await mountPage();

    expect(
      wrapper.find('[data-testid="channels-no-active-agents"]').text()
    ).toBe('CAPTAIN.CHANNEL_MATRIX.NO_ACTIVE_AGENTS');
    expect(
      wrapper
        .findAll('[role="switch"]')
        .every(input => input.attributes('disabled') === undefined)
    ).toBe(true);

    await wrapper.findAll('[role="switch"]')[1].trigger('click');
    await wrapper.find('[data-testid="save"]').trigger('click');
    await flushPromises();
    expect(state.save).toHaveBeenCalledWith({
      channels: [{ inbox_id: 6, ai_enabled: true }],
    });
  });

  it('says there are no agents when the workspace has none', async () => {
    state.matrix = payload([]);
    state.fetch.mockResolvedValue(state.matrix);
    const wrapper = await mountPage();

    expect(wrapper.find('[data-testid="channels-no-agents"]').text()).toBe(
      'CAPTAIN.CHANNEL_MATRIX.NO_AGENTS'
    );
    expect(
      wrapper.find('[data-testid="channels-no-active-agents"]').exists()
    ).toBe(false);
  });

  it('shows no notice while at least one agent is on', async () => {
    const wrapper = await mountPage();

    expect(
      wrapper.find('[data-testid="channels-no-active-agents"]').exists()
    ).toBe(false);
    expect(wrapper.find('[data-testid="channels-no-agents"]').exists()).toBe(
      false
    );
  });
});
