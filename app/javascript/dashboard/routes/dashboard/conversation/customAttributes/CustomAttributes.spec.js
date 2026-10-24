import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import { DuplicateContactException } from 'shared/helpers/CustomErrors';
import CustomAttributes from './CustomAttributes.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  alert: vi.fn(),
  definitions: [],
}));
const PATIENT_CARD = {
  medelement_patient_code: 'P-100',
  medelement_last_synced_at: '2026-10-01 10:00',
  address: 'Almaty',
  secondary_phones: '+77010000000',
  iin: '900101300123',
  clinical_note: 'Patient value',
};
vi.mock('dashboard/composables/store', async () => {
  const { ref } = await import('vue');
  return {
    useStore: () => ({ dispatch: mocks.dispatch }),
    useStoreGetters: () => ({
      getSelectedChat: ref({ id: 123, meta: { sender: { id: 42 } } }),
      'attributes/getAttributesByModel': ref(() => mocks.definitions),
      'contacts/getContact': ref(id => ({
        id,
        custom_attributes:
          id === 90
            ? PATIENT_CARD
            : {
                clinical_note: id === 84 ? 'Patient value' : 'Chat owner value',
              },
      })),
    }),
  };
});
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
}));
vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await import('vue');
  return {
    useUISettings: () => ({ uiSettings: ref({}), updateUISettings: vi.fn() }),
  };
});

describe('CustomAttributes explicit patient context', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });
  it('reads and writes the same selected patient rather than the shared chat owner', async () => {
    const wrapper = shallowMount(CustomAttributes, {
      props: {
        attributeType: 'contact_attribute',
        contactId: 84,
        attributeFrom: 'conversation_contact_panel',
      },
      global: { mocks: { $t: key => key } },
    });
    expect(wrapper.vm.customAttributes).toEqual({
      clinical_note: 'Patient value',
    });
    await wrapper.vm.onUpdate('new_field', 'New patient value');
    // Only the changed key goes to the server, which merges it into the card.
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/update', {
      id: 84,
      customAttributes: { new_field: 'New patient value' },
    });
  });
  it('ignores an attribute save response after the patient panel has unmounted', async () => {
    let resolve;
    mocks.dispatch.mockReturnValueOnce(
      new Promise(callback => {
        resolve = callback;
      })
    );
    const wrapper = shallowMount(CustomAttributes, {
      props: {
        attributeType: 'contact_attribute',
        contactId: 84,
        attributeFrom: 'conversation_contact_panel',
      },
      global: { mocks: { $t: key => key } },
    });
    const saving = wrapper.vm.onUpdate('new_field', 'Patient value');
    wrapper.unmount();
    resolve();
    await saving;
    expect(mocks.alert).not.toHaveBeenCalled();
  });
});

describe('CustomAttributes fields MedElement owns', () => {
  const definition = (attributeKey, displayType = 'text') => ({
    id: attributeKey.length,
    attribute_key: attributeKey,
    attribute_display_name: attributeKey,
    attribute_display_type: displayType,
  });
  const mountPatientPanel = (contactId = 90) =>
    shallowMount(CustomAttributes, {
      props: {
        attributeType: 'contact_attribute',
        contactId,
        attributeFrom: 'conversation_contact_panel',
      },
      global: { mocks: { $t: key => key } },
    });
  const readOnlyKeys = wrapper =>
    wrapper.vm.filteredCustomAttributes
      .filter(attribute => attribute.readOnly)
      .map(attribute => attribute.key)
      .sort();

  beforeEach(() => {
    vi.clearAllMocks();
    mocks.definitions = [
      'medelement_patient_code',
      'medelement_last_synced_at',
      'address',
      'secondary_phones',
      'iin',
      'clinical_note',
    ].map(key => definition(key));
  });

  it('shows the fields MedElement writes as read-only, with the reason', () => {
    const wrapper = mountPatientPanel();

    expect(readOnlyKeys(wrapper)).toEqual([
      'address',
      'medelement_last_synced_at',
      'medelement_patient_code',
      'secondary_phones',
    ]);
    const address = wrapper.vm.filteredCustomAttributes.find(
      attribute => attribute.key === 'address'
    );
    expect(address.readOnlyHint).toBe(
      'CUSTOM_ATTRIBUTES.READ_ONLY.PROVIDER_OWNED'
    );
    const note = wrapper.vm.filteredCustomAttributes.find(
      attribute => attribute.key === 'clinical_note'
    );
    expect(note.readOnlyHint).toBe('');
  });

  it('keeps address editable on a card that is not a patient card', () => {
    const wrapper = mountPatientPanel(84);

    // medelement_ keys stay read-only even when empty, address does not.
    expect(readOnlyKeys(wrapper)).toEqual([
      'medelement_last_synced_at',
      'medelement_patient_code',
    ]);
  });

  it('never makes a conversation attribute read-only', () => {
    mocks.definitions = [definition('medelement_patient_code')];
    const wrapper = shallowMount(CustomAttributes, {
      props: {
        attributeType: 'conversation_attribute',
        attributeFrom: 'conversation_panel',
      },
      global: { mocks: { $t: key => key } },
    });

    expect(readOnlyKeys(wrapper)).toEqual([]);
  });

  it('shows the text the server refused with instead of the generic error', async () => {
    const refusal = 'custom_attributes.address is managed by the system';
    const error = new DuplicateContactException();
    error.message = refusal;
    mocks.dispatch.mockRejectedValueOnce(error);
    const wrapper = mountPatientPanel();

    await wrapper.vm.onUpdate('address', 'Astana');
    expect(mocks.alert).toHaveBeenCalledWith(refusal);

    mocks.dispatch.mockRejectedValueOnce(new Error('Network Error'));
    await wrapper.vm.onUpdate('clinical_note', 'x');
    expect(mocks.alert).toHaveBeenLastCalledWith(
      'CUSTOM_ATTRIBUTES.FORM.UPDATE.ERROR'
    );
  });

  it('shows the refusal text when a delete is refused', async () => {
    const error = new DuplicateContactException();
    error.message = 'custom_attributes.address is managed by the system';
    mocks.dispatch.mockRejectedValueOnce(error);
    const wrapper = mountPatientPanel();

    await wrapper.vm.onDelete('address');

    expect(mocks.alert).toHaveBeenCalledWith(
      'custom_attributes.address is managed by the system'
    );
  });
});
