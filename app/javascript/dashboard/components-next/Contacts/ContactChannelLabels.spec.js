import { describe, expect, it, vi } from 'vitest';
import { nextTick } from 'vue';
import { shallowMount } from '@vue/test-utils';
import ContactChannelLabels from './ContactChannelLabels.vue';

const contactInboxes = [
  {
    sourceId: '+77001234567',
    inbox: {
      id: 1,
      name: 'One Link WhatsApp',
      channelType: 'Channel::Whatsapp',
    },
  },
  {
    sourceId: '+77007654321',
    inbox: { id: 2, name: 'Clinic WhatsApp', channelType: 'Channel::Whatsapp' },
  },
  {
    sourceId: 'user@example.com',
    inbox: { id: 3, name: 'Support Email', channelType: 'Channel::Email' },
  },
  {
    sourceId: 'fb-user',
    inbox: { id: 4, name: 'Facebook', channelType: 'Channel::FacebookPage' },
  },
];
const mount = props =>
  shallowMount(ContactChannelLabels, {
    props: { contactInboxes, copyOnClick: false, ...props },
    global: { mocks: { $t: key => key } },
  });

describe('ContactChannelLabels', () => {
  it('groups same-brand inboxes into one logo with a count and full tooltip', async () => {
    const wrapper = mount({ iconOnly: true });
    expect(wrapper.findAll('[data-test="channel-group"]')).toHaveLength(3);
    expect(wrapper.findAll('[data-test="channel-count"]')).toHaveLength(1);
    expect(wrapper.find('[data-test="channel-count"]').text()).toBe('2');
    expect(wrapper.find('[data-test="channel-group"] button').text()).toBe('2');
    const tooltip = wrapper.findAll('[data-test="channel-tooltip"]')[0];
    expect(tooltip.text()).toContain(
      'WhatsApp · One Link WhatsApp · +77001234567'
    );
    expect(tooltip.text()).toContain(
      'WhatsApp · Clinic WhatsApp · +77007654321'
    );
    await wrapper
      .findAll('[data-test="channel-group"]')[0]
      .find('button')
      .trigger('click');
    expect(
      wrapper
        .findAll('[data-test="channel-group"]')[0]
        .find('button')
        .attributes('aria-expanded')
    ).toBe('true');
  });

  it('keeps the full label display where icon-only mode is not requested', () => {
    const wrapper = mount();
    expect(wrapper.text()).toContain(
      'Email · Support Email · user@example.com'
    );
    expect(
      wrapper.find('[data-testid="new-conversation-indicator"]').exists()
    ).toBe(false);
  });

  it.each([[], [1], null])(
    'keeps the new-conversation indicator absent for %s',
    inboxIds => {
      const wrapper = mount({ existingConversationInboxIds: inboxIds });
      expect(
        wrapper.find('[data-testid="new-conversation-indicator"]').exists()
      ).toBe(false);
    }
  );

  it('shows every requested channel brand as one round icon', () => {
    const types = [
      'Channel::Whatsapp',
      'Channel::Telegram',
      'Channel::Instagram',
      'Channel::FacebookPage',
      'Channel::Voice',
      'Channel::Email',
      'Channel::WebWidget',
      'Channel::Api',
    ];
    const wrapper = mount({
      iconOnly: true,
      contactInboxes: types.map((channelType, index) => ({
        sourceId: `identity-${index}`,
        inbox: { id: index + 1, name: `Inbox ${index}`, channelType },
      })),
    });
    expect(wrapper.findAll('[data-test="channel-group"]')).toHaveLength(8);
    expect(
      wrapper
        .findAll('[data-test="channel-group"] button')
        .map(button => button.attributes('aria-label'))
    ).toEqual(
      expect.arrayContaining([
        'WhatsApp',
        'Telegram',
        'Instagram',
        'Facebook',
        'Calls',
        'Email',
        'Website chat',
        'API',
      ])
    );
  });

  it('opens the inbox tooltip on a mobile long press', async () => {
    vi.useFakeTimers();
    try {
      const wrapper = mount({ iconOnly: true });
      const button = wrapper.find('[data-test="channel-group"] button');
      await button.trigger('touchstart');
      vi.advanceTimersByTime(450);
      await nextTick();
      expect(button.attributes('aria-expanded')).toBe('true');
      await button.trigger('touchend');
      await button.trigger('click');
      expect(button.attributes('aria-expanded')).toBe('true');
    } finally {
      vi.useRealTimers();
    }
  });
});
