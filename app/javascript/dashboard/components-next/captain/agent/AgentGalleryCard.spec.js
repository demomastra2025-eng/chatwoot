/* eslint-disable vue/one-component-per-file */
import { describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

import AgentGalleryCard from './AgentGalleryCard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key} ${JSON.stringify(params)}` : key),
    te: () => true,
  }),
}));

const AvatarStub = defineComponent({
  name: 'Avatar',
  props: {
    src: { type: String, default: '' },
    name: { type: String, default: '' },
    size: { type: Number, default: 32 },
    roundedFull: Boolean,
  },
  setup: () => () => h('span', { 'data-testid': 'avatar' }),
});

// Renders a real <button> so a click bubbles to the card unless stopped.
const SwitchStub = defineComponent({
  name: 'Switch',
  props: { modelValue: Boolean, disabled: Boolean },
  emits: ['update:modelValue'],
  setup(props, { emit }) {
    return () =>
      h('button', {
        type: 'button',
        'data-testid': 'agent-active-switch',
        'aria-checked': String(props.modelValue),
        onClick: () => emit('update:modelValue', !props.modelValue),
      });
  },
});

const assistant = {
  id: 7,
  name: 'Мөлдір',
  avatar_url: 'https://example.com/avatar.png',
  routing_description: 'Записывает пациентов на приём',
  active: true,
};

const mountCard = (props = {}) =>
  mount(AgentGalleryCard, {
    props: { assistant, ...props },
    global: {
      stubs: {
        Avatar: AvatarStub,
        Switch: SwitchStub,
        Icon: true,
      },
    },
  });

describe('AgentGalleryCard', () => {
  it('shows the avatar, the name and the routing description', () => {
    const wrapper = mountCard();

    const avatar = wrapper.findComponent({ name: 'Avatar' });
    expect(avatar.props()).toMatchObject({
      src: assistant.avatar_url,
      name: 'Мөлдір',
      size: 40,
      roundedFull: true,
    });
    expect(wrapper.text()).toContain('Мөлдір');
    expect(wrapper.text()).toContain('Записывает пациентов на приём');
    expect(
      wrapper.find('[data-testid="agent-description-hint"]').exists()
    ).toBe(false);
  });

  it('asks to add a description when the agent has none', () => {
    const wrapper = mountCard({
      assistant: { ...assistant, routing_description: '  ' },
    });

    expect(wrapper.find('[data-testid="agent-description-hint"]').text()).toBe(
      'CAPTAIN.GALLERY.CARD.NO_DESCRIPTION'
    );
  });

  it('shows the status as text instead of a switch to non-administrators', () => {
    const wrapper = mountCard({
      assistant: { ...assistant, active: false },
      canToggle: false,
    });

    expect(wrapper.find('[data-testid="agent-active-switch"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-testid="agent-status"]').text()).toBe(
      'CAPTAIN.ASSISTANTS.ROUTING.INACTIVE_STATUS'
    );
  });

  it('gives administrators the active switch instead of the status text', () => {
    const wrapper = mountCard({ canToggle: true });

    const toggle = wrapper.findComponent({ name: 'Switch' });
    expect(toggle.exists()).toBe(true);
    expect(toggle.props('modelValue')).toBe(true);
    expect(wrapper.find('[data-testid="agent-status"]').exists()).toBe(false);
  });

  it('opens the agent on a click or Enter on the card', async () => {
    const wrapper = mountCard({ canToggle: true });
    const card = wrapper.find('[data-testid="agent-gallery-card"]');

    await card.trigger('click');
    await card.trigger('keydown', { key: 'Enter' });

    expect(wrapper.emitted('open')).toHaveLength(2);
  });

  it('toggles the agent from the switch without opening the card', async () => {
    const wrapper = mountCard({ canToggle: true });

    await wrapper.find('[data-testid="agent-active-switch"]').trigger('click');

    expect(wrapper.emitted('toggle-active')).toEqual([[false]]);
    expect(wrapper.emitted('open')).toBeUndefined();
  });

  it('shows the picked value while saving and falls back when the save fails', async () => {
    const wrapper = mountCard({ canToggle: true });
    const switchValue = () =>
      wrapper.findComponent({ name: 'Switch' }).props('modelValue');

    await wrapper.find('[data-testid="agent-active-switch"]').trigger('click');
    await wrapper.setProps({ toggling: true });
    expect(switchValue()).toBe(false);

    // The parent kept the stored value (the save failed).
    await wrapper.setProps({ toggling: false });
    expect(switchValue()).toBe(true);
  });

  it('summarises the channels of the agent', () => {
    const wrapper = mountCard({
      stats: { scope: 'selected', mainCount: 2, memberCount: 3 },
    });

    expect(wrapper.find('[data-testid="agent-channels-line"]').text()).toBe(
      'CAPTAIN.GALLERY.CARD.CHANNELS_LINE {"main":2,"total":3}'
    );
  });

  it('says «all channels» when the channel count is unknown', () => {
    const wrapper = mountCard({
      stats: { scope: 'all', mainCount: 1, memberCount: null },
    });

    expect(wrapper.find('[data-testid="agent-channels-line"]').text()).toBe(
      'CAPTAIN.GALLERY.CARD.ALL_CHANNELS {"main":1}'
    );
  });

  it('says when the agent works on no channel', () => {
    const wrapper = mountCard({
      stats: { scope: 'selected', mainCount: 0, memberCount: 0 },
    });

    expect(wrapper.find('[data-testid="agent-channels-line"]').text()).toBe(
      'CAPTAIN.GALLERY.CARD.NO_CHANNELS'
    );
  });

  it('hides the channel line without stats', () => {
    const wrapper = mountCard({ stats: null });

    expect(wrapper.find('[data-testid="agent-channels-line"]').exists()).toBe(
      false
    );
  });
});
