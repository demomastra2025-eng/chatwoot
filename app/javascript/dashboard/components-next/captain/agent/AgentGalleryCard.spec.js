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
    iconName: { type: String, default: null },
    roundedFull: Boolean,
  },
  setup(props) {
    return () =>
      h('span', {
        'data-testid': 'avatar',
        'data-src': props.src,
        'data-name': props.name,
        'data-size': props.size,
        'data-icon-name': props.iconName,
        'data-rounded-full': props.roundedFull,
      });
  },
});

// Renders a real <button> so a click bubbles to the card unless stopped.
const SwitchStub = defineComponent({
  name: 'SwitchStub',
  props: { modelValue: Boolean, disabled: Boolean },
  emits: ['update:modelValue'],
  setup(props, { emit }) {
    return () =>
      h('button', {
        type: 'button',
        'data-testid': 'agent-active-switch',
        'aria-checked': String(props.modelValue),
        disabled: props.disabled,
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
  it('shows the AI agent avatar with icon fallback, name and routing description', () => {
    const wrapper = mountCard();

    const avatar = wrapper.findComponent({ name: 'Avatar' });
    expect(avatar.props()).toMatchObject({
      src: assistant.avatar_url,
      name: 'Мөлдір',
      size: 40,
      iconName: 'i-woot-captain',
      roundedFull: true,
    });
    expect(wrapper.text()).toContain('Мөлдір');
    expect(wrapper.text()).toContain('Записывает пациентов на приём');
    expect(
      wrapper.find('[data-testid="agent-description-hint"]').exists()
    ).toBe(false);
    expect(wrapper.find('[data-testid="agent-channels-line"]').exists()).toBe(
      false
    );
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

    const toggle = wrapper.findComponent({ name: 'SwitchStub' });
    expect(toggle.exists()).toBe(true);
    expect(toggle.props('modelValue')).toBe(true);
    expect(wrapper.find('[data-testid="agent-status"]').exists()).toBe(false);
  });

  it('marks the starred agent and prevents switching it off', () => {
    const wrapper = mountCard({ canToggle: true, isMain: true });

    expect(wrapper.find('[data-testid="agent-main-label"]').text()).toBe(
      'CAPTAIN.GALLERY.CARD.MAIN'
    );
    expect(
      wrapper.find('[data-testid="agent-active-switch"]').attributes('disabled')
    ).toBeDefined();
    expect(wrapper.find('[data-testid="agent-make-main"]').exists()).toBe(
      false
    );
  });

  it('can star another active agent without opening its card', async () => {
    const wrapper = mountCard({ canToggle: true });

    await wrapper.find('[data-testid="agent-make-main"]').trigger('click');

    expect(wrapper.emitted('makeMain')).toHaveLength(1);
    expect(wrapper.emitted('open')).toBeUndefined();
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

    expect(wrapper.emitted('toggleActive')).toEqual([[false]]);
    expect(wrapper.emitted('open')).toBeUndefined();
  });

  it('shows the picked value while saving and falls back when the save fails', async () => {
    const wrapper = mountCard({ canToggle: true });
    const switchValue = () =>
      wrapper.findComponent({ name: 'SwitchStub' }).props('modelValue');

    await wrapper.find('[data-testid="agent-active-switch"]').trigger('click');
    await wrapper.setProps({ toggling: true });
    expect(switchValue()).toBe(false);

    // The parent kept the stored value (the save failed).
    await wrapper.setProps({ toggling: false });
    expect(switchValue()).toBe(true);
  });
});
