import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import CaptainSenderAvatars from './CaptainSenderAvatars.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) => {
      if (key === 'CAPTAIN.CHAT_AVATARS.MORE') return `+${params.count}`;
      return key;
    },
    te: () => true,
  }),
}));

const AvatarStub = {
  name: 'Avatar',
  props: {
    name: { type: String, default: '' },
    src: { type: String, default: '' },
    size: { type: Number, default: 32 },
    roundedFull: { type: Boolean, default: false },
  },
  template:
    '<span data-testid="avatar-stub" :data-name="name" :data-src="src" :data-size="size" :data-rounded="roundedFull" />',
};

const contributors = [
  { id: 1, name: 'A', avatarUrl: 'https://cdn.test/a.png' },
  { id: 2, name: 'B', avatarUrl: '' },
  { id: 3, name: 'C', avatarUrl: '' },
  { id: 4, name: 'D', avatarUrl: '' },
];

const mountComponent = props =>
  mount(CaptainSenderAvatars, {
    props,
    global: {
      stubs: { Avatar: AvatarStub },
    },
  });

const avatars = wrapper => wrapper.findAll('[data-testid="avatar-stub"]');
const moreChip = wrapper =>
  wrapper.find('[data-testid="captain-sender-avatars-more"]');

describe('CaptainSenderAvatars', () => {
  it('renders one round avatar per contributor with photo or initials', () => {
    const wrapper = mountComponent({ contributors: contributors.slice(0, 2) });
    const rendered = avatars(wrapper);

    expect(rendered).toHaveLength(2);
    expect(rendered[0].attributes('data-name')).toBe('A');
    expect(rendered[0].attributes('data-src')).toBe('https://cdn.test/a.png');
    // Empty src lets Avatar fall back to the initials of the name.
    expect(rendered[1].attributes('data-name')).toBe('B');
    expect(rendered[1].attributes('data-src')).toBe('');
    expect(rendered[0].attributes('data-size')).toBe('24');
    expect(rendered[0].attributes('data-rounded')).toBe('true');
    expect(moreChip(wrapper).exists()).toBe(false);
  });

  it('shows at most three avatars and a +N chip for the rest', () => {
    const wrapper = mountComponent({ contributors });

    expect(
      avatars(wrapper).map(avatar => avatar.attributes('data-name'))
    ).toEqual(['A', 'B', 'C']);
    expect(moreChip(wrapper).text()).toBe('+1');
  });

  it('respects a custom limit and size', () => {
    const wrapper = mountComponent({ contributors, max: 2, size: 32 });

    expect(avatars(wrapper)).toHaveLength(2);
    expect(avatars(wrapper)[0].attributes('data-size')).toBe('32');
    expect(moreChip(wrapper).text()).toBe('+2');
    expect(moreChip(wrapper).attributes('style')).toContain('width: 32px');
  });

  it('accepts snake_case avatar urls', () => {
    const wrapper = mountComponent({
      contributors: [
        { id: 9, name: 'Doctor', avatar_url: 'https://cdn.test/d.png' },
      ],
    });

    expect(avatars(wrapper)[0].attributes('data-src')).toBe(
      'https://cdn.test/d.png'
    );
  });

  it('renders nothing inside without contributors', () => {
    const wrapper = mountComponent({ contributors: [] });

    expect(avatars(wrapper)).toHaveLength(0);
    expect(moreChip(wrapper).exists()).toBe(false);
  });
});
