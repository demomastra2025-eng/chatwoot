import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ConversationStatusFilter from './ConversationStatusFilter.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const mountComponent = props =>
  mount(ConversationStatusFilter, {
    props: { modelValue: 'open', ...props },
    global: {
      directives: { 'on-clickaway': {} },
    },
  });

const openMenu = async wrapper => {
  await wrapper
    .get('[data-test-id="conversation-status-filter-trigger"]')
    .trigger('click');
};

const optionValues = wrapper =>
  wrapper
    .findAll('[role="menuitemradio"]')
    .map(option =>
      option
        .attributes('data-test-id')
        .replace('conversation-status-filter-option-', '')
    );

describe('ConversationStatusFilter', () => {
  it('offers all, open, snoozed and resolved without Captain', async () => {
    const wrapper = mountComponent();

    await openMenu(wrapper);

    expect(optionValues(wrapper)).toEqual([
      'all',
      'open',
      'snoozed',
      'resolved',
    ]);
  });

  it('adds the pending (AI) status only when Captain is enabled', async () => {
    const wrapper = mountComponent({ showAi: true });

    await openMenu(wrapper);

    expect(optionValues(wrapper)).toEqual([
      'all',
      'open',
      'pending',
      'snoozed',
      'resolved',
    ]);
  });

  it('keeps an already selected pending list labelled without Captain', async () => {
    const wrapper = mountComponent({ modelValue: 'pending' });

    expect(
      wrapper.get('[data-test-id="conversation-status-filter-trigger"]').text()
    ).toBe('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.pending.TEXT');

    await openMenu(wrapper);
    expect(optionValues(wrapper)).toContain('pending');
  });

  it('shows the active status label and marks it as checked', async () => {
    const wrapper = mountComponent({ modelValue: 'resolved' });

    expect(
      wrapper.get('[data-test-id="conversation-status-filter-trigger"]').text()
    ).toBe('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.resolved.TEXT');

    await openMenu(wrapper);
    const checked = wrapper.find('[aria-checked="true"]');
    expect(checked.attributes('data-test-id')).toBe(
      'conversation-status-filter-option-resolved'
    );
  });

  it('emits the selected status and closes the menu', async () => {
    const wrapper = mountComponent();

    await openMenu(wrapper);
    await wrapper
      .get('[data-test-id="conversation-status-filter-option-all"]')
      .trigger('click');

    expect(wrapper.emitted('update:modelValue')).toEqual([['all']]);
    expect(
      wrapper.find('[data-test-id="conversation-status-filter-menu"]').exists()
    ).toBe(false);
  });

  it('does not emit when the current status is selected again', async () => {
    const wrapper = mountComponent();

    await openMenu(wrapper);
    await wrapper
      .get('[data-test-id="conversation-status-filter-option-open"]')
      .trigger('click');

    expect(wrapper.emitted('update:modelValue')).toBeUndefined();
  });

  it('does not add a gray background to the trigger or status options', async () => {
    const wrapper = mountComponent();
    const trigger = wrapper.get(
      '[data-test-id="conversation-status-filter-trigger"]'
    );
    expect(trigger.classes()).not.toContain('hover:bg-n-alpha-2');

    await openMenu(wrapper);
    wrapper.findAll('[role="menuitemradio"]').forEach(option => {
      expect(option.classes()).not.toContain('hover:bg-n-alpha-2');
      expect(option.classes()).not.toContain('bg-n-alpha-2');
    });
  });
});
