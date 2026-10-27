import { describe, expect, it, vi, afterEach } from 'vitest';
import { defineComponent, ref } from 'vue';
import { mount, flushPromises } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { useSchedulingAppointmentFormStore } from 'dashboard/stores/scheduling/appointmentForm';
import {
  patientSearchKind,
  useMedelementPatientSearch,
  visibleRemotePatients,
} from './useMedelementPatientSearch';

const validIin = () => {
  const digits = [...'00010150000'].map(Number);
  const checksum = weights =>
    weights.reduce((sum, weight, index) => sum + weight * digits[index], 0) %
    11;
  const first = checksum([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  const result =
    first === 10 ? checksum([3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]) : first;
  return `${digits.join('')}${result === 10 ? 0 : result}`;
};

const setup = (enabled = true) => {
  const search = vi.fn();
  const importPatient = vi.fn();
  const onImported = vi.fn();
  let state;
  const wrapper = mount(
    defineComponent({
      setup() {
        state = useMedelementPatientSearch({
          enabled: ref(enabled),
          search,
          importPatient,
          onImported,
        });
        return () => null;
      },
    })
  );
  return { state, search, importPatient, onImported, wrapper };
};

afterEach(() => {
  vi.useRealTimers();
  vi.clearAllMocks();
});

describe('MedElement patient picker search', () => {
  it('classifies IIN, phone, name length and mixed text without sending invalid text', () => {
    const iin = validIin();
    expect(patientSearchKind(iin)).toBe('iin');
    expect(
      patientSearchKind(`${iin.slice(0, 11)}${(Number(iin[11]) + 1) % 10}`)
    ).toBe('');
    expect(patientSearchKind('8 (701) 000-00-01')).toBe('phone');
    expect(patientSearchKind('Ая')).toBe('');
    expect(patientSearchKind('Аян')).toBe('name');
    expect(patientSearchKind('Ая Аян')).toBe('name');
    expect(patientSearchKind('Ая Аян Болат')).toBe('name');
    expect(patientSearchKind('Ая Аян Болат Ұлан')).toBe('');
    expect(patientSearchKind('Аян 123')).toBe('');
  });

  it('debounces three fast edits into one request and ignores the same text twice', async () => {
    vi.useFakeTimers();
    const { state, search, wrapper } = setup();
    search.mockResolvedValue({ patients: [], truncated: false });
    state.query('Ая');
    state.query('Аян');
    state.query('Аян Қ');
    state.query('Аян Қуаныш');
    await vi.advanceTimersByTimeAsync(400);
    expect(search).toHaveBeenCalledTimes(1);
    state.query('Аян Қуаныш');
    await vi.advanceTimersByTimeAsync(400);
    expect(search).toHaveBeenCalledTimes(1);
    wrapper.unmount();
  });

  it('drops a stale answer while keeping the current result and local options', async () => {
    vi.useFakeTimers();
    let resolveOld;
    const { state, search, wrapper } = setup();
    search
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveOld = resolve;
          })
      )
      .mockResolvedValueOnce({ patients: [{ token: 'new' }] });
    state.query('Аян');
    await vi.advanceTimersByTimeAsync(400);
    state.query('Қуаныш');
    await vi.advanceTimersByTimeAsync(400);
    resolveOld({ patients: [{ token: 'old' }] });
    await flushPromises();
    expect(state.patients.value).toEqual([{ token: 'new' }]);
    expect(
      visibleRemotePatients(
        [
          { token: 'a', linkedContactId: 1 },
          { token: 'b', linkedContactId: 2 },
        ],
        [{ value: 1 }]
      )
    ).toEqual([{ token: 'b', linkedContactId: 2 }]);
    wrapper.unmount();
  });

  it('shows a calm failure, imports once, and stays silent without a hook', async () => {
    vi.useFakeTimers();
    const { state, search, importPatient, onImported, wrapper } = setup();
    search.mockRejectedValueOnce(new Error('provider failed'));
    state.query('Аян');
    await vi.advanceTimersByTimeAsync(400);
    expect(state.error.value).toBe(true);
    expect(state.patients.value).toEqual([]);
    importPatient.mockResolvedValue({ id: 42 });
    await state.select({ token: 'opaque' });
    expect(importPatient).toHaveBeenCalledTimes(1);
    expect(onImported).toHaveBeenCalledWith({ id: 42 });
    wrapper.unmount();

    const disabled = setup(false);
    disabled.state.query('Аян');
    await vi.advanceTimersByTimeAsync(400);
    expect(disabled.search).not.toHaveBeenCalled();
    disabled.wrapper.unmount();
  });

  it('hands the imported contact to the appointment form without requiring a phone', async () => {
    setActivePinia(createPinia());
    const form = useSchedulingAppointmentFormStore();
    form.openCreate();
    const contact = {
      id: 42,
      firstName: 'Аян',
      lastName: 'Қуаныш',
      fullName: 'Қуаныш Аян',
      phone: '',
      customAttributes: { medelement_patient_code: 'fake-patient-1' },
    };
    const importPatient = vi.fn().mockResolvedValue(contact);
    let state;
    const wrapper = mount(
      defineComponent({
        setup() {
          state = useMedelementPatientSearch({
            enabled: ref(true),
            search: vi.fn(),
            importPatient,
            onImported: imported => {
              form.contacts = [imported];
              form.applyContact(imported);
            },
          });
          return () => null;
        },
      })
    );

    await state.select({ token: 'opaque' });

    expect(importPatient).toHaveBeenCalledWith('opaque');
    expect(form.selectedContact).toEqual(contact);
    expect(form.form.clientFirstName).toBe('Аян');
    expect(form.isProviderPatientCodeLinked).toBe(true);
    expect(form.form.clientPhone).toBe('');
    wrapper.unmount();
  });
});
