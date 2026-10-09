import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import {
  conversationPatientContextKey,
  formatPatientBirthDate,
  PATIENT_SELECTION_STORAGE_KEY,
  useConversationPatientContextStore,
} from './patientContext';

vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: { patients: vi.fn(), createPatient: vi.fn(), update: vi.fn() },
}));

const key = '74:9:conversation:123';
const owner = {
  id: 42,
  account_id: 74,
  communication_contact_id: 42,
  patient_contact_id: null,
  selectable_patient: false,
  full_name: 'Owner',
};
const patient = {
  id: 84,
  account_id: 74,
  communication_contact_id: 42,
  patient_contact_id: 84,
  selectable_patient: true,
  full_name: 'Patient',
};
const response = (patients = [owner, patient], contactId = 42) => ({
  data: { payload: { contact_id: contactId, patients } },
});
const deferred = () => {
  let resolve;
  const promise = new Promise(callback => {
    resolve = callback;
  });
  return { promise, resolve };
};

describe('conversation patient context', () => {
  beforeEach(() => {
    window.localStorage.clear();
    setActivePinia(createPinia());
    vi.clearAllMocks();
    SchedulingContactsAPI.patients.mockResolvedValue(response());
  });

  it('scopes remembered selection by account, employee, and dialog kind', () => {
    const context = { accountId: 74, userId: 9, chat: { id: 123 } };
    expect(conversationPatientContextKey(context)).toBe(key);
    expect(conversationPatientContextKey({ ...context, userId: 10 })).not.toBe(
      key
    );
    expect(
      conversationPatientContextKey({ ...context, accountId: 75 })
    ).not.toBe(key);
    expect(
      conversationPatientContextKey({
        ...context,
        chat: { id: 123, is_communication_thread: true },
      })
    ).not.toBe(key);
    expect(conversationPatientContextKey({ ...context, userId: null })).toBe(
      ''
    );
  });

  it('loads without creating a card and remembers only IDs', async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    expect(store.selectedPatient(key).id).toBe(42);
    expect(SchedulingContactsAPI.createPatient).not.toHaveBeenCalled();
    expect(store.select(key, 84)).toBe(true);
    expect(
      JSON.parse(window.localStorage.getItem(PATIENT_SELECTION_STORAGE_KEY))
    ).toEqual({ [key]: 84 });
    store.saveDraft(`${key}:84`, {
      createForm: { clientName: 'Private draft' },
    });
    expect(
      window.localStorage.getItem(PATIENT_SELECTION_STORAGE_KEY)
    ).not.toContain('Private');
  });

  it('restores this employee selection after store recreation', async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    store.select(key, 84);
    setActivePinia(createPinia());
    const restored = useConversationPatientContextStore();
    await restored.load(key, 42);
    expect(restored.selectedPatient(key).id).toBe(84);
    const otherEmployee = '74:10:conversation:123';
    await restored.load(otherEmployee, 42);
    expect(restored.selectedPatient(otherEmployee).id).toBe(42);
  });

  it('rejects missing, cross-account, and other-chat candidates', async () => {
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([
        owner,
        { ...patient, account_id: 75 },
        { ...patient, id: 85, communication_contact_id: 43 },
      ])
    );
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    expect(store.contexts[key].patients).toEqual([owner]);
    expect(store.select(key, 84)).toBe(false);
  });

  it('ignores a response overtaken by a forced reload', async () => {
    const first = deferred();
    SchedulingContactsAPI.patients.mockReturnValueOnce(first.promise);
    const store = useConversationPatientContextStore();
    const request = store.load(key, 42);
    await store.load(key, 42, { force: true });
    store.select(key, 84);
    first.resolve(response([owner]));
    await request;
    expect(store.selectedPatient(key).id).toBe(84);
  });

  it('does not apply an old owner response to a replaced dialog context', async () => {
    const first = deferred();
    SchedulingContactsAPI.patients.mockReturnValueOnce(first.promise);
    const store = useConversationPatientContextStore();
    const request = store.load(key, 42);
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([{ ...owner, id: 43, communication_contact_id: 43 }], 43)
    );
    await store.load(key, 43);
    first.resolve(response());
    await request;
    expect(store.selectedPatient(key).id).toBe(43);
  });

  it('adds a separate patient only after an explicit action', async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    SchedulingContactsAPI.createPatient.mockResolvedValue({
      data: {
        payload: {
          ...patient,
          id: 85,
          patient_contact_id: 85,
        },
      },
    });
    await store.createPatient(key, {
      first_name: 'New',
      last_name: 'Patient',
      conversation_display_id: 123,
      idempotency_key: 'a08ac654-22e8-4eee-a325-6f9421c4f283',
    });
    expect(SchedulingContactsAPI.createPatient).toHaveBeenCalledWith(42, {
      first_name: 'New',
      last_name: 'Patient',
      conversation_display_id: 123,
      idempotency_key: 'a08ac654-22e8-4eee-a325-6f9421c4f283',
    });
    expect(store.selectedPatient(key).id).toBe(85);
  });

  it('does not replace a changed selection with a late create response', async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    const pending = deferred();
    SchedulingContactsAPI.createPatient.mockReturnValueOnce(pending.promise);
    const request = store.createPatient(key, {
      first_name: 'New',
      last_name: 'Patient',
      idempotency_key: 'a08ac654-22e8-4eee-a325-6f9421c4f283',
    });
    store.select(key, 84);
    pending.resolve({
      data: { payload: { ...patient, id: 85, patient_contact_id: 85 } },
    });
    expect(await request).toBeNull();
    expect(store.selectedPatient(key).id).toBe(84);
  });

  it('keeps card relationship metadata when editing clinical details', async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    store.select(key, 84);
    SchedulingContactsAPI.update.mockResolvedValue({
      data: {
        payload: {
          id: 84,
          account_id: 74,
          full_name: 'Raw contact response',
        },
      },
    });
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([owner, { ...patient, full_name: 'Changed Patient' }])
    );
    await store.updatePatient(key, 84, { first_name: 'Changed' });
    expect(store.selectedPatient(key)).toMatchObject({
      patient_contact_id: 84,
      communication_contact_id: 42,
      full_name: 'Changed Patient',
    });
    expect(SchedulingContactsAPI.patients).toHaveBeenLastCalledWith(42);
    expect(store.contexts[key].selectedId).toBe(84);
    expect(
      await store.updatePatient(key, 42, { first_name: 'Owner' })
    ).toBeNull();
  });

  it.each([
    {
      ...owner,
      patient_contact_id: 42,
      custom_attributes: { medelement_patient_code: 'owner-profile' },
    },
    {
      ...patient,
      custom_attributes: { medelement_patient_code: 'patient-profile' },
    },
    { ...patient, custom_attributes: { medelement_iin: 'recorded-iin' } },
  ])(
    'does not patch provider clinical identity or the communication owner',
    async selected => {
      SchedulingContactsAPI.patients.mockResolvedValue(
        response([owner, selected])
      );
      const store = useConversationPatientContextStore();
      await store.load(key, 42);
      store.select(key, selected.id);
      expect(
        await store.updatePatient(key, selected.id, {
          birth_date: '2010-02-03',
        })
      ).toBeNull();
      expect(SchedulingContactsAPI.update).not.toHaveBeenCalled();
    }
  );

  it('ignores a patient PATCH completed after the employee selects another patient', async () => {
    const other = {
      ...patient,
      id: 85,
      patient_contact_id: 85,
      full_name: 'Other patient',
    };
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([owner, patient, other])
    );
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    store.select(key, 84);
    const pending = deferred();
    SchedulingContactsAPI.update.mockReturnValueOnce(pending.promise);
    const request = store.updatePatient(key, 84, { birth_date: '2010-02-03' });
    store.select(key, 85);
    pending.resolve({ data: { payload: { id: 84, account_id: 74 } } });
    expect(await request).toBeNull();
    expect(SchedulingContactsAPI.patients).toHaveBeenCalledTimes(1);
    expect(store.selectedPatient(key)).toEqual(other);
  });

  it('ignores a clinical projection completed after the employee selects another patient', async () => {
    const other = {
      ...patient,
      id: 85,
      patient_contact_id: 85,
      full_name: 'Other patient',
    };
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([owner, patient, other])
    );
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    store.select(key, 84);
    SchedulingContactsAPI.update.mockResolvedValue({
      data: { payload: { id: 84, account_id: 74 } },
    });
    const pending = deferred();
    SchedulingContactsAPI.patients.mockReturnValueOnce(pending.promise);
    const request = store.updatePatient(key, 84, { birth_date: '2010-02-03' });
    await Promise.resolve();
    store.select(key, 85);
    pending.resolve(
      response([owner, { ...patient, birth_date: '2010-02-03' }])
    );
    expect(await request).toBeNull();
    expect(store.selectedPatient(key)).toEqual(other);
  });

  it('rejects a cross-account projection after a local card update', async () => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    store.select(key, 84);
    SchedulingContactsAPI.update.mockResolvedValue({
      data: { payload: { id: 84, account_id: 74 } },
    });
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([owner, { ...patient, account_id: 75 }])
    );
    await expect(
      store.updatePatient(key, 84, { birth_date: '2010-02-03' })
    ).rejects.toThrow('patient_context_mismatch');
    expect(store.selectedPatient(key)).toEqual(patient);
  });

  it('formats a birth date without shifting it by browser timezone', () => {
    expect(formatPatientBirthDate({ birth_date: '2017-01-02' })).toBe(
      '02.01.2017'
    );
    expect(formatPatientBirthDate({})).toBe('');
  });
});
