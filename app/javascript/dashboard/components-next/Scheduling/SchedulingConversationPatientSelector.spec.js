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

  it('autofills only the new patient from a valid IIN and keeps the mother and separated names intact', async () => {
    const mother = {
      ...owner,
      first_name: 'Mother',
      last_name: 'Family',
      identifier: '940720300129',
      birth_date: '1994-07-20',
      gender: 'female',
    };
    SchedulingContactsAPI.patients.mockResolvedValueOnce({
      data: { payload: { contact_id: 42, patients: [mother] } },
    });
    SchedulingContactsAPI.createPatient.mockResolvedValueOnce({
      data: { payload: patient },
    });
    const wrapper = await mountLoaded();
    expect(wrapper.vm.form).toMatchObject({
      iin: '',
      birth_date: '',
      gender: 'unknown',
    });
    wrapper.vm.startCreate();
    Object.assign(wrapper.vm.form, {
      first_name: ' Child ',
      last_name: ' Family ',
      middle_name: ' Middle ',
      iin: '170102500010',
    });
    expect(wrapper.vm.form).toMatchObject({
      birth_date: '2017-01-02',
      gender: 'male',
      first_name: ' Child ',
      last_name: ' Family ',
      middle_name: ' Middle ',
    });
    await wrapper.vm.savePatient();
    expect(SchedulingContactsAPI.createPatient).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        iin: '170102500010',
        birth_date: '2017-01-02',
        gender: 'male',
        first_name: 'Child',
        last_name: 'Family',
        middle_name: 'Middle',
        conversation_display_id: 123,
      })
    );
    expect(mother).toMatchObject({
      identifier: '940720300129',
      birth_date: '1994-07-20',
      gender: 'female',
    });
    expect(wrapper.vm.form).toMatchObject({
      iin: '',
      birth_date: '',
      gender: 'unknown',
    });
  });

  it.each([
    '170102500011',
    '991332500010',
    '170102700010',
    '1701025000101',
    '170102',
  ])(
    'rejects invalid IIN %s without inferring patient data or sending a request',
    async iin => {
      const wrapper = await mountLoaded();
      wrapper.vm.startCreate();
      Object.assign(wrapper.vm.form, {
        first_name: 'Child',
        last_name: 'Family',
        iin,
      });
      expect(wrapper.vm.isInvalid).toBe(true);
      expect(wrapper.vm.form).toMatchObject({
        birth_date: '',
        gender: 'unknown',
      });
      await wrapper.vm.savePatient();
      expect(SchedulingContactsAPI.createPatient).not.toHaveBeenCalled();
    }
  );

  it('clears previous inferred values after an invalid IIN but preserves manual birth date and gender', async () => {
    const wrapper = await mountLoaded();
    wrapper.vm.startCreate();
    wrapper.vm.form.iin = '170102500010';
    wrapper.vm.form.iin = '170102500011';
    expect(wrapper.vm.form).toMatchObject({
      birth_date: '',
      gender: 'unknown',
    });
    wrapper.vm.form.iin = '170102500010';
    wrapper.vm.form.birth_date = '2017-01-03';
    wrapper.vm.form.gender = 'other';
    wrapper.vm.form.iin = '';
    expect(wrapper.vm.form).toMatchObject({
      birth_date: '2017-01-03',
      gender: 'other',
    });
    await wrapper.setProps({ contextKey: '74:9:conversation:124' });
    expect(wrapper.vm.form).toMatchObject({
      iin: '',
      birth_date: '',
      gender: 'unknown',
    });
    expect(wrapper.vm.isCreating).toBe(false);
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
