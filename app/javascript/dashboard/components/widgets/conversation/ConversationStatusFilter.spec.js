import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ConversationStatusFilter from './ConversationStatusFilter.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

describe('ConversationStatusFilter', () => {
  it('does not add a gray background to the trigger or status options', async () => {
    const wrapper = mount(ConversationStatusFilter, {
      props: { modelValue: 'open' },
      global: {
        directives: { 'on-clickaway': {} },
      },
    });

    const trigger = wrapper.get(
      '[data-test-id="conversation-status-filter-trigger"]'
    );
    expect(trigger.classes()).not.toContain('hover:bg-n-alpha-2');

    await trigger.trigger('click');
    const options = wrapper.findAll('[role="menuitemradio"]');

    expect(options).toHaveLength(4);
    options.forEach(option => {
      expect(option.classes()).not.toContain('hover:bg-n-alpha-2');
      expect(option.classes()).not.toContain('bg-n-alpha-2');
    });
  });
});
