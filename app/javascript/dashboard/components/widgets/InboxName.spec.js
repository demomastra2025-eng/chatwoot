import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import InboxName from './InboxName.vue';

const mountComponent = props =>
  mount(InboxName, {
    props: {
      inbox: { id: 1, name: 'Inbox' },
      ...props,
    },
    global: {
      stubs: {
        ChannelIcon: true,
      },
    },
  });

describe('InboxName', () => {
  it('truncates the visible inbox name when maxLength is set', () => {
    const wrapper = mountComponent({
      inbox: { id: 1, name: 'Very Long Inbox Name' },
      maxLength: 12,
    });

    expect(wrapper.text()).toBe('Very Long In…');
    expect(wrapper.attributes('title')).toBe('Very Long Inbox Name');
  });
});
