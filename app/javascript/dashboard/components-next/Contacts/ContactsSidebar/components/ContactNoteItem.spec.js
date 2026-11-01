import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import ContactNoteItem from './ContactNoteItem.vue';

vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({ formatMessage: value => value }),
}));

describe('ContactNoteItem', () => {
  it('exposes a named delete action that emits the existing note id', async () => {
    const wrapper = shallowMount(ContactNoteItem, {
      props: {
        note: { id: 42, content: 'Synthetic note', createdAt: 1700000000 },
        writtenBy: 'Synthetic author',
        allowDelete: true,
      },
      global: {
        stubs: { Button: false },
        directives: { dompurifyHtml: () => {} },
      },
    });
    const button = wrapper.get('button[aria-label="Delete note"]');
    await button.trigger('click');
    expect(wrapper.emitted('delete')).toEqual([[42]]);
    await wrapper.setProps({ allowDelete: false });
    expect(wrapper.find('button[aria-label="Delete note"]').exists()).toBe(
      false
    );
  });
});
