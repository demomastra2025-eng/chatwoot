import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import ConversationLocalSearch from './ConversationLocalSearch.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('dashboard/composables/emitter', () => ({
  useEmitter: vi.fn(),
}));

describe('ConversationLocalSearch', () => {
  const mountSearch = (modelValue = '') =>
    mount(ConversationLocalSearch, {
      props: {
        isOnExpandedLayout: false,
        modelValue,
      },
      global: {
        mocks: { $t: key => key },
        directives: { tooltip: () => {} },
        stubs: {
          NextButton: {
            name: 'NextButton',
            props: ['color', 'ariaPressed'],
            template: '<button data-test-id="open-search-btn" />',
          },
        },
      },
    });

  it('highlights the trigger button and clears the query when inline clear button is clicked', async () => {
    const wrapper = mountSearch('Айгерим');
    const triggerBtn = wrapper.getComponent({ name: 'NextButton' });
    expect(triggerBtn.props('color')).toBe('blue');

    await wrapper.find('[data-test-id="open-search-btn"]').trigger('click');
    const clearBtn = wrapper.find('[data-test-id="local-search-clear-input"]');
    expect(clearBtn.exists()).toBe(true);

    await clearBtn.trigger('click');
    expect(wrapper.emitted('update:modelValue')).toEqual([['']]);
  });

  it('hides the inline clear button when the query is empty', async () => {
    const wrapper = mountSearch('');
    const triggerBtn = wrapper.getComponent({ name: 'NextButton' });
    expect(triggerBtn.props('color')).toBe('slate');

    await wrapper.find('[data-test-id="open-search-btn"]').trigger('click');
    expect(
      wrapper.find('[data-test-id="local-search-clear-input"]').exists()
    ).toBe(false);
  });
});
