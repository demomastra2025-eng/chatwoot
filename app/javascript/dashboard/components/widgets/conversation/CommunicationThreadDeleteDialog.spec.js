import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CommunicationThreadDeleteDialog from './CommunicationThreadDeleteDialog.vue';

const dialogOpen = vi.fn();
const dialogClose = vi.fn();

const channels = [
  {
    conversation_id: 11,
    inbox_id: 101,
    inbox_name: 'WhatsApp Sales',
    channel: 'Channel::Whatsapp',
    source_id: '+77000000001',
  },
  {
    conversation_id: 12,
    inbox_id: 102,
    inbox_name: 'Telegram Support',
    channel: 'Channel::Telegram',
    source_id: '@support',
  },
];

const mountComponent = props =>
  mount(CommunicationThreadDeleteDialog, {
    props: {
      threadId: 7,
      channels,
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        Dialog: {
          props: [
            'title',
            'description',
            'confirmButtonLabel',
            'disableConfirmButton',
          ],
          emits: ['confirm'],
          methods: {
            open: dialogOpen,
            close: dialogClose,
          },
          template:
            '<section data-test-id="dialog" :data-disabled="disableConfirmButton"><slot name="description" /><slot /><button data-test-id="confirm" @click="$emit(\'confirm\')">confirm</button></section>',
        },
      },
    },
  });

describe('CommunicationThreadDeleteDialog', () => {
  it('requires an explicit channel selection before confirming deletion', async () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('[data-test-id="dialog"]').attributes('data-disabled')
    ).toBe('true');

    await wrapper.find('[data-test-id="delete-channel-11"]').setValue(true);
    await wrapper.find('[data-test-id="confirm"]').trigger('click');

    expect(wrapper.emitted('confirm')).toEqual([[[11]]]);
  });

  it('renders channel identity so operators can choose exact channels', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('WhatsApp Sales');
    expect(wrapper.text()).toContain('0001');
    expect(wrapper.text()).toContain('Telegram Support');
    expect(wrapper.text()).toContain('@support');
  });

  it('ignores unlinked channels without a concrete child conversation id', async () => {
    const wrapper = mountComponent({
      channels: [
        ...channels,
        {
          conversation_id: null,
          inbox_id: 103,
          inbox_name: 'Unlinked Instagram',
          channel: 'Channel::Instagram',
        },
      ],
    });

    expect(wrapper.find('[data-test-id="delete-channel-NaN"]').exists()).toBe(
      false
    );
    expect(wrapper.text()).not.toContain('Unlinked Instagram');

    await wrapper.find('input[type="checkbox"]').setValue(true);
    await wrapper.find('[data-test-id="confirm"]').trigger('click');

    expect(wrapper.emitted('confirm')).toEqual([[[11, 12]]]);
  });
});
