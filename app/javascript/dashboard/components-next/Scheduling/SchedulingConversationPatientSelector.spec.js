import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { shallowMount } from '@vue/test-utils';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import { useConversationPatientContextStore } from 'dashboard/stores/scheduling/patientContext';
import SchedulingConversationPatientSelector from './SchedulingConversationPatientSelector.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: { patients: vi.fn(), createPatient: vi.fn() },
}));

const key = '74:9:conversation:123';
const owner = { id: 42, account_id: 74, communication_contact_id: 42 };
const patient = {
  id: 84,
  account_id: 74,
  communication_contact_id: 42,
  patient_contact_id: 84,
  selectable_patient: true,
};

describe('conversation patient selector', () => {
  let pinia;
  beforeEach(() => {
    pinia = createPinia();
    setActivePinia(pinia);
    window.localStorage.clear();
    vi.clearAllMocks();
    SchedulingContactsAPI.patients.mockResolvedValue({
      data: {
        payload: {
          contact_id: 42,
          patients: [owner],
        },
      },
    });
  });

  const mountLoaded = async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    return shallowMount(SchedulingConversationPatientSelector, {
      props: {
        contextKey: key,
        entry: store.contexts[key],
        conversationDisplayId: 123,
      },
      global: { plugins: [pinia] },
    });
  };

  it('creates no card on view or when opening the empty form', async () => {
    const wrapper = await mountLoaded();
    wrapper.vm.startCreate();
    expect(SchedulingContactsAPI.createPatient).not.toHaveBeenCalled();
    expect(wrapper.vm.isCreating).toBe(true);
  });

  it('reuses the same creation key after a network error and sends the original dialog display ID', async () => {
    const wrapper = await mountLoaded();
    wrapper.vm.startCreate();
    Object.assign(wrapper.vm.form, {
      first_name: 'Patient',
      last_name: 'Family',
    });
    SchedulingContactsAPI.createPatient.mockRejectedValueOnce(
      new Error('Network error')
    );
    await wrapper.vm.savePatient();
    SchedulingContactsAPI.createPatient.mockResolvedValueOnce({
      data: { payload: patient },
    });
    await wrapper.vm.savePatient();
    const first = SchedulingContactsAPI.createPatient.mock.calls[0];
    const second = SchedulingContactsAPI.createPatient.mock.calls[1];
    expect(first[0]).toBe(42);
    expect(first[1]).toMatchObject({ conversation_display_id: 123 });
    expect(first[1].idempotency_key).toMatch(
      /^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$/i
    );
    expect(second[1].idempotency_key).toBe(first[1].idempotency_key);
    expect(first[1]).not.toHaveProperty('phone');
    wrapper.vm.startCreate();
    expect(wrapper.vm.idempotencyKey).not.toBe(first[1].idempotency_key);
  });
});
