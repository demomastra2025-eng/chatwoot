import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import SchedulingContactsAPI from 'dashboard/api/scheduling/contacts';
import { useConversationPatientContextStore } from 'dashboard/stores/scheduling/patientContext';
import SchedulingPatientDetails from './SchedulingPatientDetails.vue';

vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: { patients: vi.fn(), update: vi.fn() },
}));

const InputStub = defineComponent({
  props: ['modelValue', 'label', 'type', 'disabled'],
  emits: ['update:modelValue'],
  setup:
    (props, { emit }) =>
    () =>
      h('label', [
        props.label,
        h('input', {
          'data-label': props.label,
          type: props.type || 'text',
          value: props.modelValue,
          disabled: props.disabled,
          onInput: event => emit('update:modelValue', event.target.value),
        }),
      ]),
});
const ButtonStub = defineComponent({
  props: ['label', 'type', 'disabled'],
  emits: ['click'],
  setup:
    (props, { emit }) =>
    () =>
      h(
        'button',
        {
          type: props.type || 'button',
          disabled: props.disabled,
          onClick: event => emit('click', event),
        },
        props.label
      ),
});
const SelectStub = defineComponent({
  props: ['modelValue', 'options', 'disabled'],
  emits: ['update:modelValue'],
  setup:
    (props, { emit }) =>
    () =>
      h(
        'select',
        {
          value: props.modelValue,
          disabled: props.disabled,
          onChange: event => emit('update:modelValue', event.target.value),
        },
        props.options.map(option =>
          h('option', { value: option.value }, option.label)
        )
      ),
});

const key = '74:9:conversation:123';
const owner = {
  id: 42,
  account_id: 74,
  communication_contact_id: 42,
  patient_contact_id: null,
  full_name: 'Chat owner alias',
};
const patient = {
  id: 84,
  account_id: 74,
  communication_contact_id: 42,
  patient_contact_id: 84,
  selectable_patient: true,
  full_name: 'Local Family',
  first_name: 'Local',
  last_name: 'Family',
  middle_name: 'Relative',
  identifier: '090101500000',
  birth_date: '2009-01-01',
  gender: 'male',
  phone: '+77001234567',
  custom_attributes: { medelement_patient_card: true },
};
const otherPatient = {
  ...patient,
  id: 85,
  patient_contact_id: 85,
  full_name: 'Other Patient',
  first_name: 'Other',
  last_name: 'Patient',
};
const response = patients => ({
  data: { payload: { contact_id: 42, patients } },
});
const deferred = () => {
  let resolve;
  const promise = new Promise(callback => {
    resolve = callback;
  });
  return { promise, resolve };
};

describe('SchedulingPatientDetails', () => {
  let pinia;
  beforeEach(() => {
    window.localStorage.clear();
    pinia = createPinia();
    setActivePinia(pinia);
    vi.clearAllMocks();
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([owner, patient, otherPatient])
    );
  });

  const mountSelected = async id => {
    const store = useConversationPatientContextStore();
    await store.load(key, 42);
    store.select(key, id);
    const wrapper = mount(
      defineComponent({
        setup: () => () =>
          h(SchedulingPatientDetails, {
            patient: store.selectedPatient(key),
            contextKey: key,
          }),
      }),
      {
        global: {
          plugins: [pinia],
          stubs: { Input: InputStub, Button: ButtonStub, Select: SelectStub },
        },
      }
    );
    return { wrapper, store };
  };

  it.each([42, 84])(
    'renders provider patient %s readonly without changing the chat owner alias',
    async id => {
      const chatOwner = {
        id: 42,
        name: 'Chat owner alias',
        identifier: 'Original identifier',
      };
      const before = { ...chatOwner };
      const clinical = {
        ...patient,
        id,
        patient_contact_id: id,
        full_name: 'Recorded Clinical Patient',
        gender: 2,
        custom_attributes: {
          medelement_patient_code: 'recorded-profile',
          medelement_first_name: 'Recorded',
          medelement_last_name: 'Clinical',
        },
      };
      SchedulingContactsAPI.patients.mockResolvedValue(
        response(id === 42 ? [clinical, patient] : [owner, clinical])
      );
      const { wrapper, store } = await mountSelected(id);
      expect(wrapper.text()).toContain('Recorded Clinical Patient');
      expect(
        wrapper.find('[data-test="patient-provider-source"]').text()
      ).toContain('MedElement');
      expect(wrapper.find('button').exists()).toBe(false);
      expect(wrapper.find('form').exists()).toBe(false);
      expect(
        await store.updatePatient(key, id, { birth_date: '2010-02-03' })
      ).toBeNull();
      expect(SchedulingContactsAPI.update).not.toHaveBeenCalled();
      expect(chatOwner).toEqual(before);
      wrapper.unmount();
    }
  );

  it('saves only a changed local DOB and reloads the clinical projection with the selection intact', async () => {
    const { wrapper, store } = await mountSelected(84);
    await wrapper.find('button').trigger('click');
    await wrapper.find('input[type="date"]').setValue('2010-02-03');
    SchedulingContactsAPI.update.mockResolvedValue({
      data: {
        payload: {
          id: 84,
          account_id: 74,
          full_name: 'Generic PATCH alias',
        },
      },
    });
    SchedulingContactsAPI.patients.mockResolvedValue(
      response([owner, { ...patient, birth_date: '2010-02-03' }, otherPatient])
    );
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(SchedulingContactsAPI.update).toHaveBeenCalledWith(84, {
      birth_date: '2010-02-03',
    });
    expect(SchedulingContactsAPI.patients).toHaveBeenLastCalledWith(42);
    expect(store.contexts[key].selectedId).toBe(84);
    expect(wrapper.text()).toContain('Local Family');
    expect(wrapper.text()).toContain('03.02.2010');
    expect(wrapper.text()).not.toContain('Generic PATCH alias');
    expect(wrapper.find('form').exists()).toBe(false);
    expect(store.contexts[key].patients.find(item => item.id === 42)).toEqual(
      owner
    );
    wrapper.unmount();
  });

  it('does not replace patient B or leave A editing after a late local update', async () => {
    const { wrapper, store } = await mountSelected(84);
    await wrapper.find('button').trigger('click');
    await wrapper.find('input[type="date"]').setValue('2010-02-03');
    const pending = deferred();
    SchedulingContactsAPI.update.mockReturnValueOnce(pending.promise);
    await wrapper.find('form').trigger('submit');
    store.select(key, 85);
    await flushPromises();
    pending.resolve({ data: { payload: { id: 84, account_id: 74 } } });
    await flushPromises();
    expect(wrapper.text()).toContain('Other Patient');
    expect(wrapper.text()).not.toContain('Local Family');
    expect(wrapper.find('form').exists()).toBe(false);
    expect(store.selectedPatient(key)).toEqual(otherPatient);
    expect(SchedulingContactsAPI.patients).toHaveBeenCalledTimes(1);
    wrapper.unmount();
  });
});
