import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import EditContact from './EditContact.vue';

describe('EditContact', () => {
  it('opens a centered modal and saves the existing owner field', async () => {
    const dispatch = vi.fn().mockResolvedValue(null);
    const contact = { id: 14, name: 'Алия', owner_id: 7 };
    const wrapper = shallowMount(EditContact, {
      props: { show: true, contact },
      global: {
        mocks: {
          $store: {
            getters: { 'contacts/getUIFlags': {} },
            dispatch,
          },
          $t: key => key,
        },
        stubs: {
          'woot-modal': {
            template: '<div><slot /></div>',
            props: ['show', 'modalType'],
          },
          'woot-modal-header': true,
          ContactForm: {
            name: 'ContactForm',
            template: '<div />',
            props: ['contact', 'inProgress', 'onSubmit'],
          },
        },
      },
    });

    expect(wrapper.html()).toContain('modal-type="centered"');
    expect(
      wrapper.findComponent({ name: 'ContactForm' }).props('contact').owner_id
    ).toBe(7);
    await wrapper.vm.onSubmit({ ...contact, owner_id: 9 });
    expect(dispatch).toHaveBeenCalledWith('contacts/update', {
      ...contact,
      owner_id: 9,
    });
  });
});
