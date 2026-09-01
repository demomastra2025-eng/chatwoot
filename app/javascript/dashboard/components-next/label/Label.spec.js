import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import Label from './Label.vue';

const emojiLabel = {
  title: 'Priority',
  display_title: 'Priority',
  marker_type: 'emoji',
  emoji: '🔥',
};

const colorLabel = {
  title: 'Priority',
  display_title: 'Priority',
  marker_type: 'color',
  color: '#ff0000',
};

describe('Label', () => {
  it('clips an emoji marker inside a compact label', () => {
    const wrapper = mount(Label, {
      props: { label: emojiLabel, compact: true },
    });

    const emoji = wrapper.findAll('span')[0];

    expect(wrapper.classes()).toContain('overflow-hidden');
    expect(emoji.classes()).toEqual(
      expect.arrayContaining(['overflow-hidden', 'size-3', 'text-xs'])
    );
  });

  it('keeps a regular emoji marker within a fixed box', () => {
    const wrapper = mount(Label, {
      props: { label: emojiLabel },
    });

    const emoji = wrapper.findAll('span')[0];

    expect(emoji.classes()).toEqual(
      expect.arrayContaining(['overflow-hidden', 'size-3', 'text-xs'])
    );
  });

  it('renders a color marker at 8 pixels', () => {
    const wrapper = mount(Label, {
      props: { label: colorLabel },
    });

    expect(wrapper.find('span').classes()).toContain('size-2');
  });
});
