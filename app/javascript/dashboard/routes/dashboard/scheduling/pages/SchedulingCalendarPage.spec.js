import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { defineComponent, h, isReadonly, reactive, ref } from 'vue';
import { createStore } from 'vuex';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import { useSchedulingAppointmentFormStore } from 'dashboard/stores/scheduling/appointmentForm';
import CrmCustomFieldsSection from 'dashboard/components-next/CRM/CrmCustomFieldsSection.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingCalendarPage from './SchedulingCalendarPage.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  calendar: null,
  references: null,
  crm: null,
  route: { params: { accountId: '74' }, query: {} },
}));

vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key, locale: { value: 'en' } }),
}));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => mocks.route,
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(() => Promise.resolve()) }),
}));
vi.mock('dashboard/composables', async importOriginal => ({
  ...(await importOriginal()),
  useAlert: mocks.alert,
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: {
      value: { id: 74, settings: { scheduling_company_enabled: false } },
    },
  }),
}));
vi.mock('dashboard/composables/useUISettings', async importOriginal => ({
  ...(await importOriginal()),
  useUISettings: () => ({ updateUISettings: vi.fn() }),
}));
vi.mock('dashboard/stores/scheduling/calendar', () => ({
  useSchedulingCalendarStore: () => mocks.calendar,
}));
vi.mock('dashboard/stores/scheduling/references', () => ({
  useSchedulingReferencesStore: () => mocks.references,
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => mocks.crm,
}));
vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    create: vi.fn(),
    update: vi.fn(),
    cancel: vi.fn(),
    delete: vi.fn(),
  },
}));
vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: {
    get: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    patients: vi.fn(),
  },
}));
vi.mock('dashboard/api/scheduling/providerCommands', () => ({
  default: {
    create: vi.fn(),
    confirm: vi.fn(),
    get: vi.fn(),
    list: vi.fn(),
    cancel: vi.fn(),
  },
}));

const owner = {
  id: 42,
  accountId: 74,
  firstName: 'Patient',
  fullName: 'Patient',
  phone: '+77001234567',
};
const resource = { id: 3, active: true, name: 'Doctor', customAttributes: {} };
const slot = {
  resourceId: 3,
  startsAt: '2026-10-10T05:00:00Z',
  endsAt: '2026-10-10T05:30:00Z',
};
const fieldDefinitions = [
  {
    id: 99,
    active: true,
    key: 'intake_note',
    label: 'Intake note',
    fieldType: 'text',
    defaultValue: 'Original intake',
    rules: { contexts: ['booking_intake'] },
  },
  {
    id: 100,
    active: true,
    key: 'staff_note',
    label: 'Staff note',
    fieldType: 'text',
    defaultValue: 'Original staff',
    rules: {},
  },
];
const deferred = () => {
  let resolve;
  const promise = new Promise(callback => {
    resolve = callback;
  });
  return { promise, resolve };
};
const InputStub = defineComponent({
  name: 'CalendarInputStub',
  props: ['modelValue', 'label', 'disabled'],
  emits: ['update:modelValue'],
  setup:
    (props, { emit }) =>
    () =>
      h('input', {
        'data-label': props.label,
        value: props.modelValue,
        disabled: props.disabled,
        onInput: event => emit('update:modelValue', event.target.value),
      }),
});
const SelectStub = defineComponent({
  name: 'SchedulingSelectField',
  props: ['modelValue', 'label', 'disabled', 'options'],
  emits: ['update:modelValue', 'search', 'open'],
  setup:
    (props, { emit }) =>
    () =>
      h(
        'select',
        {
          'data-label': props.label,
          disabled: props.disabled,
          value: props.modelValue,
          onChange: event => emit('update:modelValue', event.target.value),
          onInput: event => emit('search', event.target.value),
          onFocus: () => emit('open'),
        },
        (props.options || []).map(option =>
          h('option', { key: option.value, value: option.value }, option.label)
        )
      ),
});
const ButtonStub = defineComponent({
  name: 'CalendarButtonStub',
  props: ['label', 'icon', 'disabled', 'isLoading'],
  emits: ['click'],
  setup:
    (props, { emit }) =>
    () =>
      h(
        'button',
        {
          type: 'button',
          'data-label': props.label,
          'data-icon': props.icon,
          disabled: props.disabled || props.isLoading,
          onClick: () => emit('click'),
        },
        props.label
      ),
});
const DatePickerStub = defineComponent({
  name: 'DateTimePicker',
  props: ['value', 'disabled'],
  emits: ['change'],
  setup:
    (props, { emit }) =>
    () =>
      h('input', {
        class: 'calendar-date-picker',
        value: props.value,
        disabled: props.disabled,
        onChange: event => emit('change', new Date(event.target.value)),
      }),
});
const TextAreaStub = defineComponent({
  name: 'TextArea',
  props: ['modelValue', 'label', 'disabled'],
  emits: ['update:modelValue'],
  setup:
    (props, { emit }) =>
    () =>
      h('textarea', {
        'data-label': props.label,
        disabled: props.disabled,
        value: props.modelValue,
        onInput: event => emit('update:modelValue', event.target.value),
      }),
});
const DialogStub = defineComponent({
  name: 'CalendarDialogStub',
  props: { renderOnOpenOnly: { type: Boolean, default: true } },
  emits: ['close'],
  setup(props, { emit, expose, slots }) {
    const isOpen = ref(false);
    const open = () => {
      isOpen.value = true;
    };
    const close = () => {
      if (!isOpen.value) return;
      isOpen.value = false;
      emit('close');
    };
    expose({ open, close });
    return () =>
      h(
        'div',
        { 'data-dialog-open': isOpen.value },
        isOpen.value || !props.renderOnOpenOnly ? slots.default?.() : []
      );
  },
});
const stubs = {
  Button: ButtonStub,
  Input: InputStub,
  TextArea: TextAreaStub,
  SchedulingDateTimeField: false,
  DateTimePicker: DatePickerStub,
  SchedulingSelectField: SelectStub,
  SchedulingFormFieldGroup: { template: '<div><slot /></div>' },
  CrmCustomFieldsSection: false,
  CrmCustomFieldDescriptionHint: true,
  PhoneNumberInput: InputStub,
  SchedulingMoneyInput: InputStub,
  TagMultiSelectComboBox: true,
  Checkbox: true,
  CrmDealConversationPanel: true,
  Dialog: DialogStub,
  SchedulingCalendarGrid: true,
  SchedulingCustomFieldAdvancedFilter: true,
  SchedulingErrorState: true,
  SchedulingMultiSelectFilter: true,
  SchedulingResourceFilter: true,
  SchedulingToolbar: true,
  SchedulingViewSwitcher: true,
  Spinner: true,
};
let wrapper;
const mountPage = async () => {
  const pinia = createPinia();
  const vuex = createStore({ getters: { getCurrentUser: () => ({ id: 9 }) } });
  setActivePinia(pinia);
  wrapper = mount(SchedulingCalendarPage, {
    global: {
      plugins: [pinia, vuex],
      stubs,
      mocks: {
        $t: key => key,
      },
    },
  });
  await flushPromises();
  const store = useSchedulingAppointmentFormStore();
  store.contacts = [owner];
  const grid = wrapper.findComponent({ name: 'SchedulingCalendarGrid' });
  // eslint-disable-next-line vue/custom-event-name-casing -- Preserve the existing calendar grid event contract.
  grid.vm.$emit('create-appointment', slot);
  await flushPromises();
  const contact = wrapper
    .findAllComponents(SelectStub)
    .find(
      field =>
        field.attributes('aria-label') === 'SCHEDULING.CONTACT.SELECT_ACTION'
    );
  contact.vm.$emit('update:modelValue', owner.id);
  await flushPromises();
  return { store, contact };
};

describe('SchedulingCalendarPage pending local booking', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.route = reactive({ params: { accountId: '74' }, query: {} });
    mocks.calendar = reactive({
      anchorDate: '2026-10-10T05:00:00Z',
      currentView: 'day',
      selectedResourceIds: [3],
      appointments: [],
      resources: [resource],
      visibleResources: [resource],
      slots: [],
      breakRules: [],
      holidays: [],
      timeOffs: [],
      workRules: [],
      workdayOverrides: [],
      statusFilters: [],
      showInactiveAppointments: false,
      ui: { error: null, isLoading: false },
      hydratePreferences: vi.fn(),
      setWorkspaceTimezone: vi.fn(),
      setSelectedResources: vi.fn(),
      setCustomAttributeFilters: vi.fn(),
      setAnchorDate: vi.fn(),
      setView: vi.fn(),
      setStatusFilters: vi.fn(),
      setShowInactiveAppointments: vi.fn(),
      fetchCalendar: vi.fn(() => Promise.resolve()),
      refresh: vi.fn(() => Promise.resolve()),
      syncAppointment: vi.fn(),
    });
    mocks.references = reactive({
      resources: [resource],
      activeResources: [resource],
      services: [],
      activeServices: [],
      loadResources: vi.fn(() => Promise.resolve()),
      loadServices: vi.fn(() => Promise.resolve()),
    });
    mocks.crm = reactive({
      appointmentFieldDefinitions: fieldDefinitions,
      loadFieldDefinitions: vi.fn(() => Promise.resolve()),
    });
  });
  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
  });

  it('locks DOM fields and late popup callbacks until one created booking is acknowledged', async () => {
    const { store, contact } = await mountPage();
    const comment = wrapper.get(
      'textarea[data-label="SCHEDULING.APPOINTMENT_FORM.COMMENT"]'
    );
    await comment.setValue('Original comment');
    const original = JSON.parse(JSON.stringify(store.form));
    const pending = deferred();
    SchedulingAppointmentsAPI.create.mockReturnValueOnce(pending.promise);
    const save = wrapper.get(
      '.modal-mask button[data-label="SCHEDULING.GENERAL.CREATE"]'
    );
    await save.trigger('click');
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledOnce();
    expect(store.ui.isSaving).toBe(true);
    const controls = wrapper.get('[data-test="appointment-form-controls"]');
    expect(controls.element.disabled).toBe(true);
    expect(controls.attributes()).toHaveProperty('inert');
    expect(
      wrapper.get('#scheduling-appointment-drawer-title').element.disabled
    ).toBe(true);
    expect(comment.element.disabled).toBe(true);

    // Simulate callbacks from popups opened before submit, even if a child
    // emits after its disabled prop changes.
    const dates = wrapper.findAllComponents(SchedulingDateTimeField);
    const startsAt = dates.find(
      field => field.props('label') === 'SCHEDULING.APPOINTMENT_FORM.STARTS_AT'
    );
    const endsAt = dates.find(
      field => field.props('label') === 'SCHEDULING.APPOINTMENT_FORM.ENDS_AT'
    );
    expect(startsAt.props('disabled')).toBe(true);
    expect(endsAt.props('disabled')).toBe(true);
    startsAt.vm.$emit('update:modelValue', '2026-10-11T11:00');
    endsAt.vm.$emit('update:modelValue', '2026-10-11T12:00');
    wrapper
      .findComponent(TextAreaStub)
      .vm.$emit('update:modelValue', 'Late comment');
    contact.vm.$emit('update:modelValue', 43);
    contact.vm.$emit('search', 'Late search');
    wrapper.findAllComponents(CrmCustomFieldsSection).forEach(section => {
      expect(section.props('disabled')).toBe(true);
      expect(isReadonly(section.props('modelValue'))).toBe(true);
      section.vm.$emit('update:modelValue', {
        intake_note: 'Late intake',
        staff_note: 'Late staff',
      });
      section
        .findComponent(InputStub)
        .vm.$emit('update:modelValue', 'Late nested popup');
    });
    await wrapper
      .get('#scheduling-appointment-drawer-title')
      .setValue('Late name');
    await comment.setValue('Late DOM comment');
    await save.trigger('click');
    await flushPromises();
    expect(store.form).toEqual(original);
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledOnce();
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        contact_id: 42,
        client_comment: 'Original comment',
        starts_at: '2026-10-10T05:00:00.000Z',
        ends_at: '2026-10-10T05:30:00.000Z',
        custom_attributes: expect.objectContaining({
          intake_note: 'Original intake',
          staff_note: 'Original staff',
        }),
      })
    );
    pending.resolve({
      data: {
        payload: {
          id: 501,
          contact_id: 42,
          starts_at: slot.startsAt,
          ends_at: slot.endsAt,
        },
      },
    });
    await flushPromises();
    expect(store.isOpen).toBe(false);
    expect(store.ui.isSaving).toBe(false);
    expect(wrapper.find('.modal-mask').exists()).toBe(false);
    expect(mocks.calendar.syncAppointment).toHaveBeenCalledOnce();
    expect(mocks.calendar.syncAppointment).toHaveBeenCalledWith(
      expect.objectContaining({ id: 501, contactId: 42 })
    );
    expect(mocks.alert).toHaveBeenCalledOnce();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledOnce();
  });

  it('keeps dismiss available during submit and preserves a subsequently opened form', async () => {
    const { store } = await mountPage();
    const pending = deferred();
    SchedulingAppointmentsAPI.create.mockReturnValueOnce(pending.promise);
    await wrapper
      .get('.modal-mask button[data-label="SCHEDULING.GENERAL.CREATE"]')
      .trigger('click');
    const dismiss = wrapper.get('.modal-mask button[data-icon="i-lucide-x"]');
    expect(dismiss.element.disabled).toBe(false);
    await dismiss.trigger('click');
    await flushPromises();
    expect(store.isOpen).toBe(false);
    expect(store.ui.isSaving).toBe(false);
    expect(wrapper.find('.modal-mask').exists()).toBe(false);
    const nextSlot = {
      ...slot,
      startsAt: '2026-10-11T05:00:00Z',
      endsAt: '2026-10-11T05:30:00Z',
    };
    const grid = wrapper.findComponent({ name: 'SchedulingCalendarGrid' });
    // eslint-disable-next-line vue/custom-event-name-casing -- Preserve the existing calendar grid event contract.
    grid.vm.$emit('create-appointment', nextSlot);
    await flushPromises();
    await wrapper.get('#scheduling-appointment-drawer-title').setValue('Other');
    const freshForm = JSON.parse(JSON.stringify(store.form));
    pending.resolve({ data: { payload: { id: 501, contact_id: 42 } } });
    await flushPromises();
    expect(store.isOpen).toBe(true);
    expect(store.form).toEqual(freshForm);
    expect(store.form.clientFirstName).toBe('Other');
    expect(mocks.calendar.syncAppointment).not.toHaveBeenCalled();
    expect(mocks.alert).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledOnce();
  });
});
