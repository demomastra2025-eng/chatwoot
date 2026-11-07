import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import ContactDetails from '../Pages/ContactDetails.vue';
import ContactsForm from './ContactsForm.vue';
import Button from '../../button/Button.vue';

const dispatch = vi.hoisted(() => vi.fn());

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: () => ref({ isUpdating: false }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useOpenPersonDialog', () => ({
  useOpenPersonDialog: () => ({ openPersonDialog: vi.fn() }),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, locale: ref('ru') }),
}));

const contact = () => ({
  id: 17,
  name: 'Alpha Beta Gamma',
  createdAt: 1793000000,
  additionalAttributes: {},
});
const field = (wrapper, key) =>
  wrapper
    .getComponent(ContactsForm)
    .get(
      `input[placeholder="CONTACTS_LAYOUT.CARD.EDIT_DETAILS_FORM.FORM.${key}.PLACEHOLDER"]`
    );
const settle = async () => {
  await flushPromises();
  await flushPromises();
};

describe('ContactsForm with the reactive ContactDetails parent', () => {
  let wrapper;

  beforeEach(() => {
    dispatch.mockResolvedValue(undefined);
    wrapper = shallowMount(ContactDetails, {
      props: { selectedContact: contact() },
      global: {
        mocks: { $t: key => key },
        stubs: {
          // Keep the actual form, Input DOM events and Vuelidate scheduling.
          ContactsForm: false,
          Input: false,
          Button: false,
          Policy: { template: '<div><slot /></div>' },
        },
      },
    });
  });

  afterEach(() => wrapper.unmount());

  it('keeps a multiword first name and the cleared last name after the parent echoes the edit', async () => {
    expect(field(wrapper, 'FIRST_NAME').element.value).toBe('Alpha Beta');
    expect(field(wrapper, 'LAST_NAME').element.value).toBe('Gamma');

    await field(wrapper, 'LAST_NAME').setValue('');
    await settle();

    expect(field(wrapper, 'FIRST_NAME').element.value).toBe('Alpha Beta');
    expect(field(wrapper, 'LAST_NAME').element.value).toBe('');
  });

  it.each(['settled', 'overlapping'])(
    'saves the intended single name after %s edits',
    async timing => {
      const clearing = field(wrapper, 'LAST_NAME').setValue('');
      if (timing === 'settled') {
        await clearing;
        await settle();
      }
      await field(wrapper, 'FIRST_NAME').setValue('Replacement');
      await clearing;
      await settle();
      const save = wrapper
        .findAllComponents(Button)
        .find(
          button =>
            button.props('label') ===
            'CONTACTS_LAYOUT.CARD.EDIT_DETAILS_FORM.UPDATE_BUTTON'
        )
        .get('button');
      expect(save.attributes('disabled')).toBeUndefined();
      await save.trigger('click');
      await settle();

      const payload = dispatch.mock.calls.find(
        ([action]) => action === 'contacts/update'
      )?.[1];
      expect(payload?.name).toBe('Replacement');
      expect(field(wrapper, 'FIRST_NAME').element.value).toBe('Replacement');
      expect(field(wrapper, 'LAST_NAME').element.value).toBe('');
    }
  );

  it('still splits a genuinely external name update for the same contact', async () => {
    // The parent watches selectedContact.id. Exercise external props directly
    // on the real child instead of assuming a same-ID parent prop refresh.
    wrapper.unmount();
    wrapper = shallowMount(ContactsForm, {
      props: { contactData: contact(), isDetailsView: true },
      global: { stubs: { Input: false } },
    });
    const firstName = () =>
      wrapper.get('input[placeholder$="FIRST_NAME.PLACEHOLDER"]');
    const lastName = () =>
      wrapper.get('input[placeholder$="LAST_NAME.PLACEHOLDER"]');
    await lastName().setValue('');
    await settle();
    await wrapper.setProps({
      contactData: { ...contact(), name: 'External Family' },
    });
    await settle();

    expect(firstName().element.value).toBe('External');
    expect(lastName().element.value).toBe('Family');
  });

  it('splits the name again when switching contacts even if the combined name matches', async () => {
    await field(wrapper, 'LAST_NAME').setValue('');
    await settle();
    await wrapper.setProps({
      selectedContact: { ...contact(), id: 18, name: 'Alpha Beta' },
    });
    await settle();

    expect(field(wrapper, 'FIRST_NAME').element.value).toBe('Alpha');
    expect(field(wrapper, 'LAST_NAME').element.value).toBe('Beta');
  });
});
