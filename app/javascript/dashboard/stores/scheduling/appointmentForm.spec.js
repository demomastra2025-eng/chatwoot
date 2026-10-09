import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';
import { useSchedulingProviderCommandsStore } from './providerCommands';
import {
  appointmentFormMutationContext,
  refreshCurrentCalendarProviderAction,
  runCurrentCalendarProviderAction,
  useSchedulingAppointmentFormStore,
} from './appointmentForm';

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    create: vi.fn(),
    createConversation: vi.fn(),
    delete: vi.fn(),
    update: vi.fn(),
    cancel: vi.fn(),
  },
}));

vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: {
    create: vi.fn(),
    get: vi.fn(),
    patients: vi.fn(),
    update: vi.fn(),
  },
}));

vi.mock('dashboard/api/scheduling/providerCommands', () => ({
  default: {
    create: vi.fn(),
    confirm: vi.fn(),
    get: vi.fn(),
    cancel: vi.fn(),
  },
}));

const localPatient = {
  id: 84,
  account_id: 74,
  patient_contact_id: 84,
  communication_contact_id: 42,
  full_name: 'Patient Family',
  first_name: 'Patient',
  last_name: 'Family',
  identifier: '090101500000',
  birth_date: '2009-01-01',
  gender: 'male',
  phone: '+77001234567',
};
const localAppointment = {
  id: 11,
  accountId: 74,
  contactId: 42,
  patientContactId: 84,
  conversationId: 12002,
  clientFirstName: 'Patient',
  clientLastName: 'Family',
  clientName: 'Patient Family',
  clientIdentifier: '090101500000',
  clientBirthDate: '2009-01-01',
  clientGender: 'male',
  clientPhone: '+77001234567',
};
const localEditor = {
  birthDate: '2009-01-01',
  firstName: 'Patient',
  lastName: 'Family',
  fullName: 'Patient Family',
  iin: '090101500000',
  gender: 'male',
  phone: '+77001234567',
};
const patientsResponse = (patients = [localPatient], contactId = 42) => ({
  data: { payload: { contact_id: contactId, patients } },
});
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((callback, rejectPromise) => {
    resolve = callback;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

describe('useSchedulingAppointmentFormStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

  it('retains the patient card and original chat owner when editing a booking', () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit({
      id: 11,
      contactId: 42,
      patientContactId: 84,
      conversationId: 12002,
      clientFirstName: 'Patient',
      clientName: 'Patient',
      clientBirthDate: '2017-01-02',
    });
    expect(store.selectedContact.id).toBe(84);
    expect(store.buildPayload()).toMatchObject({
      contact_id: 42,
      patient_contact_id: 84,
      conversation_id: 12002,
    });
  });

  it('keeps patient B open when a previous provider action finishes its calendar refresh', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const originalId = store.recordId;
    const pending = deferred();
    const closeDrawer = vi.fn(() => {
      store.close();
      store.reset();
    });
    const refresh = vi.fn(() => pending.promise);
    const request = refreshCurrentCalendarProviderAction({
      refresh,
      isCurrent: () => store.isOpen && store.recordId === originalId,
      onCurrent: closeDrawer,
    });
    store.openEdit({
      ...localAppointment,
      id: 12,
      patientContactId: 85,
      clientFirstName: 'Other',
    });
    pending.resolve();
    expect(await request).toBe(false);
    expect(refresh).toHaveBeenCalledOnce();
    expect(closeDrawer).not.toHaveBeenCalled();
    expect(store.isOpen).toBe(true);
    expect(store.recordId).toBe(12);
    expect(store.form).toMatchObject({
      patientContactId: 85,
      clientFirstName: 'Other',
    });
  });

  it('allows the current provider result to close its own drawer even if calendar refresh fails', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const closeDrawer = vi.fn(() => {
      store.close();
      store.reset();
    });
    expect(
      await refreshCurrentCalendarProviderAction({
        refresh: () => Promise.reject(new Error('Read failed')),
        isCurrent: () => store.isOpen && store.recordId === 11,
        onCurrent: closeDrawer,
      })
    ).toBe(true);
    expect(closeDrawer).toHaveBeenCalledOnce();
    expect(store.isOpen).toBe(false);
    expect(store.recordId).toBeNull();
  });

  it.each([
    ['submit', 'update'],
    ['cancel', 'cancel'],
    ['destroy', 'delete'],
  ])(
    'keeps patient B open after a late local %s and sends no dependent provider intent',
    async (action, endpoint) => {
      const store = useSchedulingAppointmentFormStore();
      const providerStore = useSchedulingProviderCommandsStore();
      store.openEdit(localAppointment);
      const context = appointmentFormMutationContext(store);
      const isCurrent = () => context === appointmentFormMutationContext(store);
      const pending = deferred();
      SchedulingAppointmentsAPI[endpoint].mockReturnValueOnce(pending.promise);
      const calendarStore = {
        currentView: 'day',
        syncAppointment: vi.fn(),
        removeAppointment: vi.fn(),
        refresh: vi.fn(),
      };
      const close = vi.fn(() => {
        store.close();
        providerStore.executeConfirmed({
          appointment_id: 11,
          operation: 'create_reception',
        });
      });
      const alert = vi.fn();
      const request = runCurrentCalendarProviderAction({
        run: () =>
          store[action](calendarStore, { isCurrent, closeOnSuccess: false }),
        isCurrent,
        onSuccess: close,
        onError: alert,
      });
      store.openEdit({
        ...localAppointment,
        id: 12,
        patientContactId: 85,
        clientFirstName: 'Other',
      });
      pending.resolve({ data: { payload: { ...localAppointment, id: 11 } } });
      expect(await request).toBeNull();
      expect(SchedulingAppointmentsAPI[endpoint]).toHaveBeenCalledOnce();
      expect(SchedulingAppointmentsAPI[endpoint].mock.calls[0][0]).toBe(11);
      expect(calendarStore.syncAppointment).not.toHaveBeenCalled();
      expect(calendarStore.removeAppointment).not.toHaveBeenCalled();
      expect(calendarStore.refresh).not.toHaveBeenCalled();
      expect(SchedulingProviderCommandsAPI.create).not.toHaveBeenCalled();
      expect(close).not.toHaveBeenCalled();
      expect(alert).not.toHaveBeenCalled();
      expect(store.isOpen).toBe(true);
      expect(store.recordId).toBe(12);
      expect(store.form).toMatchObject({
        contactId: 42,
        patientContactId: 85,
        clientFirstName: 'Other',
      });
      expect(store.ui.isSaving).toBe(false);
    }
  );

  it('preserves a reopened instance of the same form after its previous save finishes', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const pending = deferred();
    SchedulingAppointmentsAPI.update.mockReturnValueOnce(pending.promise);
    const calendarStore = { currentView: 'day', syncAppointment: vi.fn() };
    const request = store.submit(calendarStore);
    store.close();
    store.openEdit(localAppointment);
    pending.resolve({ data: { payload: localAppointment } });
    expect(await request).toBeNull();
    expect(store.isOpen).toBe(true);
    expect(store.form.patientContactId).toBe(84);
    expect(calendarStore.syncAppointment).not.toHaveBeenCalled();
  });

  it('locks the submitted form fields until its save is acknowledged', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const pending = deferred();
    SchedulingAppointmentsAPI.update.mockReturnValueOnce(pending.promise);
    const calendarStore = { currentView: 'day', syncAppointment: vi.fn() };
    const request = store.submit(calendarStore);
    store.updateField('clientFirstName', 'Unsaved edit');
    pending.resolve({ data: { payload: localAppointment } });
    expect((await request).id).toBe(11);
    expect(store.isOpen).toBe(false);
    expect(store.form.clientFirstName).toBe('Patient');
    expect(store.ui.isSaving).toBe(false);
    expect(calendarStore.syncAppointment).toHaveBeenCalledOnce();
  });

  it('keeps one pending local create intent and rejects duplicate submit or field/contact changes', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openCreate({
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00Z',
      endsAt: '2026-03-09T10:30:00Z',
    });
    store.applyContact({
      id: 42,
      firstName: 'Patient',
      fullName: 'Patient',
      phone: '+77001234567',
    });
    store.updateField('clientComment', 'Original');
    const original = JSON.parse(JSON.stringify(store.form));
    const pending = deferred();
    SchedulingAppointmentsAPI.create.mockReturnValueOnce(pending.promise);
    const calendarStore = { currentView: 'day', syncAppointment: vi.fn() };
    const request = store.submit(calendarStore);
    store.updateField('startsAt', '2026-03-10T12:00');
    store.updateField('clientComment', 'Late change');
    store.updateField('customAttributes', { late: 'change' });
    store.applyContact({ id: 43, firstName: 'Other' });
    store.applyPatientContact({ id: 85, firstName: 'Other' });
    store.beginInlineContactEdit({ firstName: 'Other' });
    expect(await store.submit(calendarStore)).toBeNull();
    expect(store.form).toEqual(original);
    pending.resolve({ data: { payload: { id: 501, contact_id: 42 } } });
    expect((await request).id).toBe(501);
    expect(store.isOpen).toBe(false);
    expect(store.ui.isSaving).toBe(false);
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledOnce();
    expect(calendarStore.syncAppointment).toHaveBeenCalledOnce();
  });

  it('checks the captured form again after the month calendar refresh', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const pending = deferred();
    SchedulingAppointmentsAPI.update.mockResolvedValueOnce({
      data: { payload: localAppointment },
    });
    const calendarStore = {
      currentView: 'month',
      syncAppointment: vi.fn(),
      refresh: vi.fn(() => pending.promise),
    };
    const context = appointmentFormMutationContext(store);
    const isCurrent = () => context === appointmentFormMutationContext(store);
    const close = vi.fn(() => store.close());
    const request = runCurrentCalendarProviderAction({
      run: () =>
        store.submit(calendarStore, { isCurrent, closeOnSuccess: false }),
      isCurrent,
      onSuccess: close,
      onError: vi.fn(),
    });
    await Promise.resolve();
    expect(calendarStore.refresh).toHaveBeenCalledOnce();
    store.openEdit({ ...localAppointment, id: 12, patientContactId: 85 });
    pending.resolve();
    expect(await request).toBeNull();
    expect(close).not.toHaveBeenCalled();
    expect(store.isOpen).toBe(true);
    expect(store.recordId).toBe(12);
  });

  it('does not project a local save into another account', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const pending = deferred();
    SchedulingAppointmentsAPI.update.mockReturnValueOnce(pending.promise);
    const calendarStore = { currentView: 'day', syncAppointment: vi.fn() };
    let accountId = 74;
    const request = store.submit(calendarStore, {
      isCurrent: () => accountId === 74,
    });
    accountId = 75;
    pending.resolve({ data: { payload: localAppointment } });
    expect(await request).toBeNull();
    expect(calendarStore.syncAppointment).not.toHaveBeenCalled();
    expect(store.isOpen).toBe(true);
  });

  it('does not let an old failed save reset the busy state or error of a newer save', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const firstSave = deferred();
    const secondSave = deferred();
    SchedulingAppointmentsAPI.update
      .mockReturnValueOnce(firstSave.promise)
      .mockReturnValueOnce(secondSave.promise);
    const calendarStore = { currentView: 'day', syncAppointment: vi.fn() };
    const first = store.submit(calendarStore);
    const rejection = expect(first).rejects.toThrow('Old save failed');
    store.openEdit({ ...localAppointment, id: 12, patientContactId: 85 });
    const second = store.submit(calendarStore, { closeOnSuccess: false });
    firstSave.reject(new Error('Old save failed'));
    await rejection;
    expect(store.ui.isSaving).toBe(true);
    expect(store.ui.error).toBeNull();
    expect(store.recordId).toBe(12);
    secondSave.resolve({
      data: { payload: { ...localAppointment, id: 12, patientContactId: 85 } },
    });
    expect((await second).id).toBe(12);
    expect(store.ui.isSaving).toBe(false);
    expect(calendarStore.syncAppointment).toHaveBeenCalledOnce();
    expect(calendarStore.syncAppointment).toHaveBeenCalledWith(
      expect.objectContaining({ id: 12 })
    );
  });

  it('continues the current saved booking into one provider create and confirmation', async () => {
    const store = useSchedulingAppointmentFormStore();
    const providerStore = useSchedulingProviderCommandsStore();
    store.openEdit(localAppointment);
    const context = appointmentFormMutationContext(store);
    const isCurrent = () => context === appointmentFormMutationContext(store);
    const calendarStore = { currentView: 'day', syncAppointment: vi.fn() };
    SchedulingAppointmentsAPI.update.mockResolvedValueOnce({
      data: { payload: localAppointment },
    });
    SchedulingProviderCommandsAPI.create.mockResolvedValueOnce({
      data: { payload: { id: 91, status: 'awaiting_confirmation' } },
    });
    SchedulingProviderCommandsAPI.confirm.mockResolvedValueOnce({
      data: { payload: { id: 91, status: 'succeeded' } },
    });
    let providerRequest;
    const close = vi.fn(appointment => {
      store.close();
      providerRequest = providerStore.executeConfirmed(
        { appointment_id: appointment.id, operation: 'create_reception' },
        { pollIntervalMs: 0 }
      );
    });
    await runCurrentCalendarProviderAction({
      run: () =>
        store.submit(calendarStore, { isCurrent, closeOnSuccess: false }),
      isCurrent,
      onSuccess: close,
      onError: vi.fn(),
    });
    await providerRequest;
    expect(close).toHaveBeenCalledOnce();
    expect(store.isOpen).toBe(false);
    expect(store.ui.isSaving).toBe(false);
    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      11,
      expect.objectContaining({ contact_id: 42, patient_contact_id: 84 })
    );
    expect(SchedulingProviderCommandsAPI.create).toHaveBeenCalledOnce();
    expect(SchedulingProviderCommandsAPI.confirm).toHaveBeenCalledOnce();
    expect(SchedulingProviderCommandsAPI.cancel).not.toHaveBeenCalled();
  });

  it('updates patient details without changing the owner or promoting the family phone', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit({
      id: 11,
      contactId: 42,
      patientContactId: 84,
      conversationId: 12002,
      clientFirstName: 'Patient',
    });
    SchedulingContactsAPI.update.mockResolvedValue({
      data: {
        payload: {
          id: 84,
          full_name: 'Changed Patient',
          first_name: 'Changed',
        },
      },
    });
    SchedulingContactsAPI.patients.mockResolvedValue(
      patientsResponse([
        {
          ...localPatient,
          full_name: 'Changed Patient',
          first_name: 'Changed',
        },
      ])
    );
    await store.updateInlineContact(84, {
      firstName: 'Changed',
      phone: '+77001234567',
    });
    expect(SchedulingContactsAPI.update.mock.calls[0][0]).toBe(84);
    expect(SchedulingContactsAPI.update.mock.calls[0][1]).not.toHaveProperty(
      'phone'
    );
    expect(store.form).toMatchObject({
      contactId: 42,
      patientContactId: 84,
      clientFirstName: 'Changed',
    });
  });

  it.each([42, 84])(
    'keeps provider patient %s readonly in the calendar contact editor',
    async patientId => {
      const store = useSchedulingAppointmentFormStore();
      const owner = {
        id: 42,
        fullName: 'Original chat alias',
        firstName: 'Original',
      };
      store.contacts = [owner];
      store.openEdit({
        ...localAppointment,
        patientContactId: patientId,
        clientFirstName: 'Clinical',
        clientName: 'Clinical Patient',
        customAttributes: { medelement_patient_code: 'verified-profile' },
      });
      expect(store.isProviderPatientIdentity).toBe(true);
      store.beginInlineContactEdit(localEditor);
      expect(store.inlineContactSnapshot).toBeNull();
      expect(
        await store.updateInlineContact(patientId, { birthDate: '2010-02-03' })
      ).toBeNull();
      expect(SchedulingContactsAPI.update).not.toHaveBeenCalled();
      expect(store.contacts[0]).toEqual(owner);
      expect(store.form).toMatchObject({
        contactId: 42,
        patientContactId: patientId,
        clientFirstName: 'Clinical',
        clientName: 'Clinical Patient',
      });
    }
  );

  it('keeps an imported provider identity readonly without requiring a new patient-card binding', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit({
      ...localAppointment,
      patientContactId: null,
      source: 'medelement',
      externalRef: 'medelement:reception:legacy-reception',
      customAttributes: { medelement_reception_code: 'legacy-reception' },
    });
    expect(store.isProviderPatientIdentity).toBe(true);
    expect(
      await store.updateInlineContact(42, { birthDate: '2010-02-03' })
    ).toBeNull();
    expect(SchedulingContactsAPI.update).not.toHaveBeenCalled();
    expect(store.selectedContact).toBeNull();
    expect(store.form.patientContactId).toBe('');
  });

  it('projects recorded clinical fields for a calendar booking without rewriting a raw chat alias', () => {
    const store = useSchedulingAppointmentFormStore();
    const owner = {
      id: 42,
      fullName: 'Messenger Alias',
      firstName: 'Messenger',
      lastName: 'Alias',
      identifier: 'raw-chat-identifier',
      phone: '+77001234567',
      customAttributes: {
        medelement_patient_code: 'verified-profile',
        medelement_first_name: 'Clinical',
        medelement_last_name: 'Patient',
        medelement_middle_name: 'Relative',
        medelement_iin: '090101500000',
        medelement_birth_date: '2009-01-01',
        medelement_gender: '2',
      },
    };
    const original = JSON.parse(JSON.stringify(owner));
    store.openCreate();
    store.applyContact(owner);
    expect(store.form).toMatchObject({
      contactId: 42,
      clientFirstName: 'Clinical',
      clientLastName: 'Patient',
      clientMiddleName: 'Relative',
      clientIdentifier: '090101500000',
      clientBirthDate: '2009-01-01',
      clientGender: 'male',
    });
    expect(store.isProviderPatientIdentity).toBe(true);
    expect(store.buildPayload()).toMatchObject({
      contact_id: 42,
      client_first_name: 'Clinical',
      client_last_name: 'Patient',
      client_identifier: '090101500000',
    });
    expect(owner).toEqual(original);
    expect(store.selectedContact).toEqual(original);
  });

  it.each([
    ['20.07.1994', '1994-07-20'],
    ['1994-07-20', '1994-07-20'],
    ['29.02.2000', '2000-02-29'],
    ['31.02.1994', ''],
    ['29.02.1900', ''],
  ])(
    'sends a valid recorded provider DOB %s in canonical form without changing the contact',
    (recorded, expected) => {
      const store = useSchedulingAppointmentFormStore();
      const owner = {
        id: 42,
        firstName: 'Messenger',
        lastName: 'Alias',
        fullName: 'Messenger Alias',
        customAttributes: {
          medelement_patient_code: 'verified-profile',
          medelement_birth_date: recorded,
          medelement_first_name: 'Clinical',
          medelement_last_name: 'Patient',
        },
      };
      const original = JSON.parse(JSON.stringify(owner));
      store.openCreate();
      store.applyContact(owner);
      expect(store.form.clientBirthDate).toBe(expected);
      if (expected)
        expect(store.buildPayload().client_birth_date).toBe(expected);
      else expect(store.buildPayload()).not.toHaveProperty('client_birth_date');
      expect(store.selectedContact).toEqual(original);
      expect(owner).toEqual(original);
    }
  );

  it('retains the authoritative clinical DTO fields instead of reprojecting its provider attributes', () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    store.applyPatientContact({
      id: 84,
      communicationContactId: 42,
      firstName: 'Server',
      lastName: 'Projection',
      fullName: 'Server Projection',
      identifier: '090101500000',
      gender: '2',
      customAttributes: {
        medelement_patient_code: 'verified-profile',
        medelement_first_name: 'Old',
      },
    });
    expect(store.form).toMatchObject({
      contactId: 42,
      patientContactId: 84,
      clientFirstName: 'Server',
      clientLastName: 'Projection',
      clientGender: 'male',
    });
  });

  it('sends only a local DOB change and reloads the scoped patient projection', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    const owner = { id: 42, accountId: 74, fullName: 'Original chat alias' };
    store.contacts = [owner];
    store.beginInlineContactEdit({ ...localEditor, resourceId: 3 });
    SchedulingContactsAPI.update.mockResolvedValue({
      data: {
        payload: {
          id: 84,
          account_id: 74,
          full_name: 'Raw PATCH alias',
        },
      },
    });
    SchedulingContactsAPI.patients.mockResolvedValue(
      patientsResponse([{ ...localPatient, birth_date: '2010-02-03' }])
    );
    await store.updateInlineContact(84, {
      ...localEditor,
      resourceId: 3,
      birthDate: '2010-02-03',
    });
    expect(SchedulingContactsAPI.update).toHaveBeenCalledWith(84, {
      birth_date: '2010-02-03',
      resource_id: 3,
    });
    expect(SchedulingContactsAPI.patients).toHaveBeenCalledWith(42);
    expect(store.form).toMatchObject({
      contactId: 42,
      patientContactId: 84,
      clientBirthDate: '2010-02-03',
      clientFirstName: 'Patient',
      clientLastName: 'Family',
    });
    expect(store.contacts.find(item => item.id === 42)).toEqual(owner);
    expect(store.selectedContact.fullName).toBe('Patient Family');
  });

  it.each(['PATCH', 'projection'])(
    'does not apply a late %s response to another calendar patient',
    async phase => {
      const store = useSchedulingAppointmentFormStore();
      store.openEdit(localAppointment);
      store.beginInlineContactEdit(localEditor);
      const pending = deferred();
      SchedulingContactsAPI.update.mockResolvedValue({
        data: { payload: { id: 84, account_id: 74 } },
      });
      if (phase === 'PATCH')
        SchedulingContactsAPI.update.mockReturnValueOnce(pending.promise);
      else SchedulingContactsAPI.patients.mockReturnValueOnce(pending.promise);
      const request = store.updateInlineContact(84, {
        ...localEditor,
        birthDate: '2010-02-03',
      });
      await Promise.resolve();
      store.openEdit({
        ...localAppointment,
        id: 12,
        patientContactId: 85,
        clientFirstName: 'Other',
      });
      pending.resolve(
        phase === 'PATCH'
          ? { data: { payload: { id: 84, account_id: 74 } } }
          : patientsResponse()
      );
      expect(await request).toBeNull();
      expect(store.form).toMatchObject({
        contactId: 42,
        patientContactId: 85,
        clientFirstName: 'Other',
      });
      expect(store.ui.isCreatingContact).toBe(false);
      expect(store.selectedContact.id).toBe(85);
    }
  );

  it('ignores an old contact edit after the same appointment has been reopened', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    store.beginInlineContactEdit(localEditor);
    const pending = deferred();
    SchedulingContactsAPI.update.mockReturnValueOnce(pending.promise);
    const request = store.updateInlineContact(84, {
      ...localEditor,
      birthDate: '2010-02-03',
    });
    store.openEdit(localAppointment);
    pending.resolve({ data: { payload: { id: 84, account_id: 74 } } });
    expect(await request).toBeNull();
    expect(store.form.clientBirthDate).toBe('2009-01-01');
    expect(SchedulingContactsAPI.patients).not.toHaveBeenCalled();
  });

  it('rejects a different account in the refreshed calendar patient projection', async () => {
    const store = useSchedulingAppointmentFormStore();
    store.openEdit(localAppointment);
    store.beginInlineContactEdit(localEditor);
    SchedulingContactsAPI.update.mockResolvedValue({
      data: { payload: { id: 84, account_id: 74 } },
    });
    SchedulingContactsAPI.patients.mockResolvedValue(
      patientsResponse([{ ...localPatient, account_id: 75 }])
    );
    await expect(
      store.updateInlineContact(84, { ...localEditor, birthDate: '2010-02-03' })
    ).rejects.toThrow('patient_context_mismatch');
    expect(store.form.clientBirthDate).toBe('2009-01-01');
  });

  it('sends the cancellation mode shown on the appointment to the cancel endpoint', async () => {
    SchedulingAppointmentsAPI.cancel.mockResolvedValue({
      data: { payload: { id: 11, status: 'cancelled' } },
    });
    const store = useSchedulingAppointmentFormStore();
    const cancellationMode = 'local_only';
    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      medelementCancellationMode: cancellationMode,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    await store.cancel({
      currentView: 'day',
      syncAppointment: vi.fn(),
    });

    expect(SchedulingAppointmentsAPI.cancel).toHaveBeenCalledWith(11, {
      medelement_cancellation_mode: cancellationMode,
    });
  });

  it('keeps the saved price when editing an appointment without changing service/resource', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    store.syncServicePricing([
      {
        basePrice: 30000,
        id: 5,
        prices: [{ active: true, price: 30000, resourceId: 3 }],
      },
    ]);

    expect(store.form.serviceAmount).toBe(20000);
  });

  it('keeps a zero saved price when editing an appointment without changing service/resource', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      serviceAmount: 0,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    store.syncServicePricing([
      {
        basePrice: 30000,
        id: 5,
        prices: [{ active: true, price: 30000, resourceId: 3 }],
      },
    ]);

    expect(store.form.serviceAmount).toBe(0);
  });

  it('updates the draft price when creating a new appointment', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate({}, { resourceId: 3 });
    store.updateField('serviceId', 5);

    store.syncServicePricing([
      {
        basePrice: 30000,
        id: 5,
        prices: [{ active: true, price: 30000, resourceId: 3 }],
      },
    ]);

    expect(store.form.serviceAmount).toBe(30000);
  });

  it('updates the draft price when the edited appointment changes service/resource', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    store.updateField('resourceId', 9);

    store.syncServicePricing([
      {
        basePrice: 26000,
        id: 5,
        prices: [{ active: true, price: 26000, resourceId: 9 }],
      },
    ]);

    expect(store.form.serviceAmount).toBe(26000);
  });

  it('does not carry or send payment fields when editing a paid appointment', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      paymentStatus: 'prepaid',
      prepaidAmount: 5000,
      prepaidPaymentMethod: 'bank_transfer',
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      settlementAmount: 3000,
      settlementPaymentMethod: 'cash',
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    store.updateField('clientComment', 'Перенос');

    expect(store.form).not.toHaveProperty('prepaidAmount');
    expect(store.form).not.toHaveProperty('prepaidPaymentMethod');
    expect(store.validationErrors).not.toHaveProperty('prepaidAmount');
    // Omitted keys keep the stored amounts on the backend (it resolves them
    // from the current record), so an edit never zeroes a prepayment.
    const payload = store.buildPayload();
    [
      'payment_status',
      'prepaid_amount',
      'prepaid_payment_method',
      'settlement_amount',
      'settlement_payment_method',
    ].forEach(key => expect(payload).not.toHaveProperty(key));
    expect(payload).toMatchObject({ client_comment: 'Перенос' });
  });

  it('persists the selected Medelement cabinet in appointment custom attributes', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate({}, { resourceId: 3 });
    store.updateField('medelementCabinetCode', '501');

    expect(store.buildPayload()).toMatchObject({
      custom_attributes: {
        medelement_cabinet_code: '501',
      },
    });
  });

  it('keeps a manually entered patient phone when selecting a contact without a phone', () => {
    const store = useSchedulingAppointmentFormStore();
    const phone = ['+7', '700', '123', '4567'].join('');

    store.openCreate();
    store.updateField('clientPhone', phone);
    store.applyContact({ id: 7, fullName: 'Айжан', phone: '' });

    expect(store.form.clientPhone).toBe(phone);
    expect(store.buildPayload()).toMatchObject({
      client_phone: phone,
      contact_id: 7,
    });
  });

  it('splits a two-part contact name when the surname field is empty', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    store.applyContact({
      firstName: 'Айжан Касымова',
      fullName: 'Айжан Касымова',
      id: 17,
      lastName: '',
    });

    expect(store.form).toMatchObject({
      clientFirstName: 'Айжан',
      clientLastName: 'Касымова',
      contactId: 17,
    });
  });

  it('loads a contact by id and keeps structured name fields separate', async () => {
    SchedulingContactsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            first_name: 'Айжан',
            full_name: 'Айжан Касымова Ерлановна',
            id: 17,
            last_name: 'Касымова',
            middle_name: 'Ерлановна',
            phone: ['+7', '700', '000', '0001'].join(''),
          },
        ],
      },
    });
    const store = useSchedulingAppointmentFormStore();
    store.openCreate();

    await store.loadContact(17);

    expect(SchedulingContactsAPI.get).toHaveBeenCalledWith({
      contact_id: 17,
      limit: 1,
    });
    expect(store.form).toMatchObject({
      clientFirstName: 'Айжан',
      clientLastName: 'Касымова',
      clientMiddleName: 'Ерлановна',
      contactId: 17,
    });
  });

  it('does not carry a previous contact phone to a phone-less contact', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    store.applyContact({ id: 7, fullName: 'Айжан', phone: '+77001234567' });
    store.applyContact({ id: 8, fullName: 'Асет', phone: '' });

    expect(store.form.clientPhone).toBe('');
  });

  it('selects a newly created inline contact for the appointment', async () => {
    SchedulingContactsAPI.create.mockResolvedValue({
      data: {
        payload: {
          first_name: 'Айжан',
          full_name: 'Айжан Касымова',
          id: 17,
          last_name: 'Касымова',
          phone: '+77000000001',
        },
      },
    });
    const store = useSchedulingAppointmentFormStore();
    store.openCreate();

    await store.createInlineContact({
      firstName: 'Айжан',
      fullName: 'Айжан Касымова',
      iin: '940720300129',
      lastName: 'Касымова',
      middleName: '',
      phone: '+770****0001',
      resourceId: 12,
    });

    expect(SchedulingContactsAPI.create).toHaveBeenCalledWith({
      first_name: 'Айжан',
      full_name: 'Айжан Касымова',
      iin: '940720300129',
      last_name: 'Касымова',
      phone: '+770****0001',
      resource_id: 12,
    });
    expect(store.contacts[0]).toMatchObject({ id: 17 });
    expect(store.selectedContact).toMatchObject({ id: 17 });
    expect(store.form).toMatchObject({
      clientFirstName: 'Айжан',
      clientLastName: 'Касымова',
      contactId: 17,
    });
  });

  it('passes the selected resource context when updating an inline contact', async () => {
    SchedulingContactsAPI.update.mockResolvedValue({
      data: { payload: { first_name: 'Айжан', id: 17 } },
    });
    const store = useSchedulingAppointmentFormStore();
    store.openCreate();

    await store.updateInlineContact(17, {
      firstName: 'Айжан',
      resourceId: 12,
    });

    expect(SchedulingContactsAPI.update).toHaveBeenCalledWith(17, {
      first_name: 'Айжан',
      resource_id: 12,
    });
  });

  // The grid shows appointments on the clinic clock (Asia/Almaty, UTC+5);
  // the drawer must show and save the same wall clock in any browser zone.
  // These expectations hold for any process TZ (run with UTC and Berlin).
  describe('clinic timezone', () => {
    it('opens a grid slot at the clinic time and saves the same instant', () => {
      const store = useSchedulingAppointmentFormStore();
      store.openCreate(
        {
          endsAt: '2026-09-29T05:30:00.000Z',
          startsAt: '2026-09-29T05:00:00.000Z',
        },
        { resourceId: 3 }
      );

      expect(store.form.startsAt).toBe('2026-09-29T10:00');
      expect(store.form.endsAt).toBe('2026-09-29T10:30');
      expect(store.buildPayload()).toMatchObject({
        ends_at: '2026-09-29T05:30:00.000Z',
        starts_at: '2026-09-29T05:00:00.000Z',
      });
    });

    it('edits an appointment at the clinic time and reads typed times there', () => {
      const store = useSchedulingAppointmentFormStore();
      store.openEdit({
        id: 9,
        endsAt: '2026-03-29T01:00:00.000Z',
        resourceId: 3,
        startsAt: '2026-03-29T00:30:00.000Z',
      });

      expect(store.form.startsAt).toBe('2026-03-29T05:30');
      expect(store.form.endsAt).toBe('2026-03-29T06:00');

      // 02:30 is inside the Berlin DST gap that night; on the clinic clock it
      // is a normal time and keeps the 30 minute duration.
      store.updateField('startsAt', '2026-03-29T02:30');
      expect(store.form.endsAt).toBe('2026-03-29T03:00');
      expect(store.buildPayload()).toMatchObject({
        ends_at: '2026-03-28T22:00:00.000Z',
        starts_at: '2026-03-28T21:30:00.000Z',
      });
    });
  });

  it('keeps the appointment duration when the start time changes', () => {
    const store = useSchedulingAppointmentFormStore();
    store.openCreate({
      endsAt: '2026-03-09T10:45:00.000Z',
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    store.updateField('startsAt', '2026-03-09T12:30');

    expect(store.form.startsAt).toBe('2026-03-09T12:30');
    expect(store.form.endsAt).toBe('2026-03-09T13:15');
  });

  it('requires a Kazakhstan E.164 phone for MedElement appointments', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    store.setRequirements({ medelementPhoneRequired: true });

    expect(store.validationErrors.clientPhone).toBe(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED'
    );

    store.updateField('clientPhone', '+14155552671');
    expect(store.validationErrors.clientPhone).toBe(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_PHONE_REQUIRED'
    );

    store.updateField('clientPhone', '+77001234567');
    expect(store.validationErrors.clientPhone).toBe('');
  });

  it('requires a last name only for MedElement appointments', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    store.updateField('clientFirstName', 'Айжан');
    expect(store.validationErrors.clientLastName).toBe('');

    store.setRequirements({ medelementIdentityRequired: true });
    expect(store.validationErrors.clientLastName).toBe(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_LAST_NAME_REQUIRED'
    );

    store.updateField('clientLastName', 'Касымова');
    expect(store.validationErrors.clientLastName).toBe('');
  });

  it('requires a selected service only for MedElement appointments', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    expect(store.validationErrors.serviceIds).toBe('');

    store.setRequirements({ medelementServiceRequired: true });
    expect(store.validationErrors.serviceIds).toBe(
      'SCHEDULING.APPOINTMENT_FORM.ERRORS.MEDELEMENT_SERVICE_REQUIRED'
    );

    store.updateField('serviceIds', [5]);
    expect(store.validationErrors.serviceIds).toBe('');
    expect(store.buildPayload()).toMatchObject({
      service_id: 5,
      service_ids: [5],
    });
  });

  it('builds structured patient names and only requires the first name', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate({}, { resourceId: 3 });
    expect(store.validationErrors.clientName).toBeTruthy();

    store.updateField('clientFirstName', 'Айжан');
    store.updateField('clientLastName', 'Касымова');
    store.updateField('clientMiddleName', 'Ерлановна');

    expect(store.validationErrors.clientName).toBe('');
    expect(store.buildPayload()).toMatchObject({
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна',
      client_name: 'Айжан Касымова Ерлановна',
    });
  });

  it('preserves legacy client names without promoting them to structured provider identity', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      clientName: 'Касымова Айжан Ерлановна',
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    expect(store.form).toMatchObject({
      clientFirstName: 'Касымова Айжан Ерлановна',
      clientLastName: '',
      clientMiddleName: '',
      clientNameStructured: false,
    });
    const payload = store.buildPayload();
    expect(payload.client_name).toBe('Касымова Айжан Ерлановна');
    expect(payload).not.toHaveProperty('client_first_name');
    expect(payload).not.toHaveProperty('client_last_name');
    expect(payload).not.toHaveProperty('client_middle_name');
  });

  it('does not echo backend-managed appointment metadata in mutation payloads', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      customAttributes: {
        medelement_cabinet_code: '501',
        medelement_reception_code: 'reception-1',
        service_ids: [5],
        services: [{ id: 5, name: 'Consultation' }],
        source_mode: 'imported',
        visit_reason: 'Initial visit',
      },
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    expect(store.buildPayload().custom_attributes).toEqual({
      medelement_cabinet_code: '501',
      visit_reason: 'Initial visit',
    });
  });

  it('hydrates the Medelement cabinet when editing an appointment', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      customAttributes: { medelement_cabinet_code: '502' },
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    expect(store.form.medelementCabinetCode).toBe('502');
  });

  it('keeps the linked conversation display id for the appointment modal chat panel', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      conversationDisplayId: 185,
      conversationId: 11963,
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    expect(store.form.conversationId).toBe(11963);
    expect(store.form.conversationDisplayId).toBe(185);
    expect(store.buildPayload()).toMatchObject({ conversation_id: 11963 });
    expect(store.buildPayload()).not.toHaveProperty('conversation_display_id');
  });

  it('sends conversation_display_id when only a display id is available', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate({}, { conversationDisplayId: 185 });

    expect(store.buildPayload()).toMatchObject({
      conversation_display_id: 185,
    });
    expect(store.buildPayload()).not.toHaveProperty('conversation_id');
  });

  it('atomically creates and links a conversation without closing the drawer', async () => {
    const store = useSchedulingAppointmentFormStore();
    const calendarStore = {
      syncAppointment: vi.fn(),
    };

    store.openEdit({
      contactId: 7,
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    SchedulingAppointmentsAPI.createConversation.mockResolvedValue({
      data: {
        payload: {
          contact_id: 7,
          conversation_display_id: 185,
          conversation_id: 11963,
          id: 11,
        },
      },
    });

    const appointment = await store.createAndLinkConversation(
      {
        contactId: 7,
        inbox: { contactInboxId: 91, sourceId: 'source-7', value: 3 },
      },
      calendarStore
    );

    expect(SchedulingAppointmentsAPI.createConversation).toHaveBeenCalledWith(
      11,
      {
        contact_id: 7,
        contact_inbox_id: 91,
        inbox_id: 3,
        source_id: 'source-7',
      }
    );
    expect(calendarStore.syncAppointment).toHaveBeenCalledWith(appointment);
    expect(store.selectedAppointment).toEqual(appointment);
    expect(store.form).toMatchObject({
      contactId: 7,
      conversationDisplayId: 185,
      conversationId: 11963,
    });
    expect(store.isOpen).toBe(true);
  });

  it('does not overwrite a different appointment opened while dialog linking is in flight', async () => {
    const store = useSchedulingAppointmentFormStore();
    const calendarStore = {
      syncAppointment: vi.fn(),
    };
    let resolveCreateConversation;

    store.openEdit({
      contactId: 7,
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    SchedulingAppointmentsAPI.createConversation.mockReturnValue(
      new Promise(resolve => {
        resolveCreateConversation = resolve;
      })
    );

    const linkPromise = store.createAndLinkConversation(
      { appointmentId: 11, contactId: 7, inbox: { value: 3 } },
      calendarStore,
      () => false
    );
    store.openEdit({
      contactId: 8,
      endsAt: '2026-03-09T11:30:00.000Z',
      id: 12,
      resourceId: 3,
      startsAt: '2026-03-09T11:00:00.000Z',
    });
    resolveCreateConversation({
      data: {
        payload: {
          contact_id: 7,
          conversation_display_id: 185,
          conversation_id: 11963,
          id: 11,
        },
      },
    });

    await linkPromise;

    expect(SchedulingAppointmentsAPI.createConversation).toHaveBeenCalledWith(
      11,
      {
        contact_id: 7,
        contact_inbox_id: undefined,
        inbox_id: 3,
        source_id: undefined,
      }
    );
    expect(calendarStore.syncAppointment).not.toHaveBeenCalled();
    expect(store.selectedAppointment).toMatchObject({ id: 12, contactId: 8 });
    expect(store.form).toMatchObject({ contactId: 8 });
  });

  it('does not restore a stale contact changed while dialog creation is in flight', async () => {
    const store = useSchedulingAppointmentFormStore();
    const calendarStore = { syncAppointment: vi.fn() };
    let resolveCreateConversation;

    store.openEdit({
      contactId: 7,
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    SchedulingAppointmentsAPI.createConversation.mockReturnValue(
      new Promise(resolve => {
        resolveCreateConversation = resolve;
      })
    );

    const linkPromise = store.createAndLinkConversation(
      { appointmentId: 11, contactId: 7, inbox: { value: 3 } },
      calendarStore,
      () => false
    );
    store.updateField('contactId', 8);
    resolveCreateConversation({
      data: {
        payload: {
          contact_id: 7,
          conversation_display_id: 185,
          conversation_id: 11963,
          id: 11,
        },
      },
    });

    await linkPromise;

    expect(calendarStore.syncAppointment).not.toHaveBeenCalled();
    expect(store.form).toMatchObject({ contactId: 8 });
    expect(store.form.conversationId).toBe('');
    expect(store.selectedAppointment).toMatchObject({ id: 11, contactId: 7 });
  });

  it('clears an old linked conversation when the appointment contact changes', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      contactId: 7,
      conversationDisplayId: 185,
      conversationId: 11963,
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    store.updateField('contactId', 8);

    expect(store.buildPayload()).toMatchObject({
      contact_id: 8,
      conversation_id: null,
    });
    expect(store.buildPayload()).not.toHaveProperty('conversation_display_id');
  });

  it('ignores an older response when same-context requests resolve out of order', async () => {
    const store = useSchedulingAppointmentFormStore();
    const calendarStore = { syncAppointment: vi.fn() };
    const resolvers = [];
    let activeRequest = 1;

    store.openEdit({
      contactId: 7,
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    SchedulingAppointmentsAPI.createConversation.mockImplementation(
      () =>
        new Promise(resolve => {
          resolvers.push(resolve);
        })
    );

    const firstRequest = store.createAndLinkConversation(
      { appointmentId: 11, contactId: 7, inbox: { value: 3 } },
      calendarStore,
      () => activeRequest === 1
    );
    activeRequest = 2;
    const secondRequest = store.createAndLinkConversation(
      { appointmentId: 11, contactId: 7, inbox: { value: 3 } },
      calendarStore,
      () => activeRequest === 2
    );

    resolvers[1]({
      data: {
        payload: {
          contact_id: 7,
          conversation_display_id: 202,
          conversation_id: 12002,
          id: 11,
        },
      },
    });
    await secondRequest;
    resolvers[0]({
      data: {
        payload: {
          contact_id: 7,
          conversation_display_id: 201,
          conversation_id: 12001,
          id: 11,
        },
      },
    });
    await firstRequest;

    expect(calendarStore.syncAppointment).toHaveBeenCalledTimes(1);
    expect(calendarStore.syncAppointment).toHaveBeenCalledWith(
      expect.objectContaining({ conversationId: 12002 })
    );
    expect(store.form.conversationId).toBe(12002);
    expect(store.selectedAppointment.conversationId).toBe(12002);
  });

  it('sends a manual service name snapshot when creating without configured services', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    store.updateField('resourceId', 3);
    store.updateField('serviceNameSnapshot', 'Осмотр');
    store.updateField('serviceAmount', 12000);

    expect(store.buildPayload()).toMatchObject({
      resource_id: 3,
      service_amount: 12000,
      service_ids: [],
      service_name_snapshot: 'Осмотр',
    });
    expect(store.buildPayload()).not.toHaveProperty('service_id');
  });

  it('sends an empty service list when an edited appointment switches to a manual service name', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      serviceNameSnapshot: 'Консультация',
      startsAt: '2026-03-09T10:00:00.000Z',
    });
    store.updateField('serviceIds', []);
    store.updateField('serviceAmount', 22000);

    expect(store.buildPayload()).toMatchObject({
      service_amount: 22000,
      service_ids: [],
      service_name_snapshot: 'Консультация',
    });
    expect(store.buildPayload()).not.toHaveProperty('service_id');
  });

  it('deletes a cancelled appointment and resets the form state', async () => {
    const store = useSchedulingAppointmentFormStore();
    const calendarStore = {
      currentView: 'week',
      refresh: vi.fn(),
      removeAppointment: vi.fn(),
    };

    SchedulingAppointmentsAPI.delete.mockResolvedValue({});
    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
      status: 'cancelled',
    });

    const deletedId = await store.destroy(calendarStore);

    expect(SchedulingAppointmentsAPI.delete).toHaveBeenCalledWith(11);
    expect(calendarStore.removeAppointment).toHaveBeenCalledWith(11);
    expect(calendarStore.refresh).not.toHaveBeenCalled();
    expect(deletedId).toBe(11);
    expect(store.isOpen).toBe(false);
    expect(store.recordId).toBe(null);
    expect(store.mode).toBe('create');
  });
});
