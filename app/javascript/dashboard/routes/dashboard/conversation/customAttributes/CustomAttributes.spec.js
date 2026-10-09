import { beforeEach, describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import CustomAttributes from './CustomAttributes.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn(), alert: vi.fn() }));
vi.mock('dashboard/composables/store', async () => {
  const { ref } = await import('vue');
  return {
    useStore: () => ({ dispatch: mocks.dispatch }),
    useStoreGetters: () => ({
      getSelectedChat: ref({ id: 123, meta: { sender: { id: 42 } } }),
      'attributes/getAttributesByModel': ref(() => []),
      'contacts/getContact': ref(id => ({ id, custom_attributes: {
        clinical_note: id === 84 ? 'Patient value' : 'Chat owner value',
      } })),
    }),
  };
});
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({ useRoute: () => ({ params: { accountId: '1' } }) }));
vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await import('vue');
  return { useUISettings: () => ({ uiSettings: ref({}), updateUISettings: vi.fn() }) };
});

describe('CustomAttributes explicit patient context', () => {
  beforeEach(() => { vi.clearAllMocks(); });
  it('reads and writes the same selected patient rather than the shared chat owner', async () => {
    const wrapper = shallowMount(CustomAttributes, {
      props: { attributeType: 'contact_attribute', contactId: 84,
        attributeFrom: 'conversation_contact_panel' },
      global: { mocks: { $t: key => key } },
    });
    expect(wrapper.vm.customAttributes).toEqual({ clinical_note: 'Patient value' });
    await wrapper.vm.onUpdate('new_field', 'New patient value');
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/update', {
      id: 84, customAttributes: { clinical_note: 'Patient value', new_field: 'New patient value' },
    });
  });
  it('ignores an attribute save response after the patient panel has unmounted', async () => {
    let resolve;
    mocks.dispatch.mockReturnValueOnce(new Promise(callback => { resolve = callback; }));
    const wrapper = shallowMount(CustomAttributes, {
      props: { attributeType: 'contact_attribute', contactId: 84,
        attributeFrom: 'conversation_contact_panel' },
      global: { mocks: { $t: key => key } },
    });
    const saving = wrapper.vm.onUpdate('new_field', 'Patient value');
    wrapper.unmount();
    resolve();
    await saving;
    expect(mocks.alert).not.toHaveBeenCalled();
  });
});
