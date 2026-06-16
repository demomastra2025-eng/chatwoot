import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import ChatListChannelFilter from './ChatListChannelFilter.vue';

const mountComponent = props =>
  mount(ChatListChannelFilter, {
    props: {
      activeKey: 'all',
      items: [
        { key: 'all', label: 'Все каналы', icon: 'i-lucide-mailbox', badge: 4 },
        {
          key: 'inbox:1',
          label: 'WhatsApp',
          inbox: { id: 1, name: 'WhatsApp', channel_type: 'Channel::Whatsapp' },
          badge: 2,
        },
      ],
      ...props,
    },
    global: {
      directives: {
        onClickaway: {},
      },
      mocks: {
        $t: key => key,
      },
      stubs: {
        Icon: {
          props: ['icon'],
          template:
            '<span data-test-id="icon" :data-icon="icon" :class="$attrs.class" />',
        },
        SidebarUnreadBadge: {
          props: ['value'],
          template:
            '<span v-if="Number(value)" data-test-id="badge">{{ value }}</span>',
        },
      },
    },
  });

describe('ChatListChannelFilter', () => {
  it('keeps the channel switcher visible with only All channels', () => {
    const wrapper = mountComponent({
      items: [{ key: 'all', label: 'Все каналы' }],
    });

    expect(
      wrapper.find('[data-test-id="chat-list-channel-filter"]').isVisible()
    ).toBe(true);
  });

  it('replaces the native select with a clean sidebar-style dropdown trigger', () => {
    const wrapper = mountComponent({ activeKey: 'inbox:1' });
    const trigger = wrapper.find(
      '[data-test-id="chat-list-channel-filter-trigger"]'
    );

    expect(wrapper.find('select').exists()).toBe(false);
    expect(trigger.exists()).toBe(true);
    expect(trigger.classes()).toEqual(
      expect.arrayContaining(['text-[15px]', 'ltr:pl-1'])
    );
    expect(trigger.text()).toContain('WhatsApp');
    expect(trigger.find('[data-test-id="icon"]').attributes('data-icon')).toBe(
      'i-woot-whatsapp'
    );
  });

  it('keeps the All channels label visible in the chat-list trigger', () => {
    const wrapper = mountComponent({ activeKey: 'all' });
    const trigger = wrapper.find(
      '[data-test-id="chat-list-channel-filter-trigger"]'
    );

    expect(trigger.text()).toContain('Все каналы');
    expect(
      trigger.find('[data-test-id="icon"]').element.parentElement.className
    ).toContain('text-current');
    expect(trigger.find('[data-test-id="icon"]').attributes('data-icon')).toBe(
      'i-lucide-mailbox'
    );
  });

  it('opens channel menu with sidebar-like rows and emits selected channel', async () => {
    const wrapper = mountComponent();
    await wrapper
      .find('[data-test-id="chat-list-channel-filter-trigger"]')
      .trigger('click');

    const menu = wrapper.find('[data-test-id="chat-list-channel-filter-menu"]');
    expect(menu.exists()).toBe(true);

    const items = menu.findAll('button');
    expect(items).toHaveLength(2);
    expect(items[0].text()).toContain('Все каналы');
    expect(items[1].text()).toContain('WhatsApp');
    expect(items[1].find('[data-test-id="icon"]').attributes('data-icon')).toBe(
      'i-woot-whatsapp'
    );

    await items[1].trigger('click');

    expect(wrapper.emitted('select')).toEqual([
      [
        expect.objectContaining({
          key: 'inbox:1',
          label: 'WhatsApp',
        }),
      ],
    ]);
    expect(
      wrapper.find('[data-test-id="chat-list-channel-filter-menu"]').exists()
    ).toBe(false);
  });

  it('closes the menu without emitting when the active channel is clicked', async () => {
    const wrapper = mountComponent();
    await wrapper
      .find('[data-test-id="chat-list-channel-filter-trigger"]')
      .trigger('click');
    await wrapper
      .find('[data-test-id="chat-list-channel-filter-menu"] button')
      .trigger('click');

    expect(wrapper.emitted('select')).toBeUndefined();
    expect(
      wrapper.find('[data-test-id="chat-list-channel-filter-menu"]').exists()
    ).toBe(false);
  });
});
