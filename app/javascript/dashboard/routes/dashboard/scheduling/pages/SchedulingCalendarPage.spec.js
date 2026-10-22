import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { defineComponent, h, isReadonly, reactive, ref } from 'vue';
import { createStore } from 'vuex';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';
import SchedulingResourcesAPI from 'dashboard/api/scheduling/resources';
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
  router: {
    back: vi.fn(),
    push: vi.fn(),
    replace: vi.fn(() => Promise.resolve()),
  },
}));

vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key, locale: { value: 'en' } }),
}));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => mocks.route,
  useRouter: () => mocks.router,
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
    show: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    cancel: vi.fn(),
    delete: vi.fn(),
  },
}));
vi.mock('dashboard/api/scheduling/resources', () => ({
  default: { get: vi.fn() },
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
const durationServices = [
  {
    id: 5,
    active: true,
    name: 'Full consultation',
    durationMin: 75,
    basePrice: 15000,
  },
  { id: 6, active: true, name: 'Follow-up', durationMin: 15, basePrice: 5000 },
];
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
  inheritAttrs: false,
  props: ['modelValue', 'label', 'disabled'],
  emits: ['update:modelValue'],
  setup:
    (props, { attrs, emit }) =>
    () =>
      h('input', {
        ...Object.fromEntries(
          Object.entries(attrs).filter(([attribute]) => attribute !== 'size')
        ),
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
  AppointmentDealSelector: true,
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
const mountPage = async (createSlot = slot) => {
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
  grid.vm.$emit('create-appointment', createSlot);
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
      hideCancelledAppointments: false,
      showInactiveAppointments: true,
      ui: { error: null, isLoading: false },
      hydratePreferences: vi.fn(),
      setWorkspaceTimezone: vi.fn(),
      setSelectedResources: vi.fn(),
      setCustomAttributeFilters: vi.fn(),
      setAnchorDate: vi.fn(),
      setView: vi.fn(),
      setStatusFilters: vi.fn(),
      setHideCancelledAppointments: vi.fn(),
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

  it('selects only active nonarchived resources from the raw API, excluding inactive specialists', async () => {
    SchedulingResourcesAPI.get.mockResolvedValue({
      data: {
        payload: [
          { id: 3, active: true, name: 'Doctor', custom_attributes: {} },
          {
            id: 4,
            active: false,
            name: 'Archived doctor',
            custom_attributes: { deleted_from_scheduling: true },
          },
          {
            id: 5,
            active: false,
            name: 'Inactive doctor',
            custom_attributes: { deleted_from_scheduling: false },
          },
        ],
      },
    });
    const pinia = createPinia();
    setActivePinia(pinia);
    const { useSchedulingReferencesStore } = await vi.importActual(
      'dashboard/stores/scheduling/references'
    );
    mocks.references = useSchedulingReferencesStore();
    vi.spyOn(mocks.references, 'loadServices').mockResolvedValue([]);
    const vuex = createStore({
      getters: { getCurrentUser: () => ({ id: 9 }) },
    });
    wrapper = mount(SchedulingCalendarPage, {
      global: {
        plugins: [pinia, vuex],
        stubs: {
          ...stubs,
          SchedulingToolbar: {
            template: '<div><slot name="actions" /></div>',
          },
          SchedulingResourceFilter: false,
          Avatar: true,
          teleport: true,
        },
        mocks: { $t: key => key },
      },
    });
    await flushPromises();
    expect(SchedulingResourcesAPI.get).toHaveBeenCalledWith({
      include_inactive: true,
    });
    const filter = wrapper.findComponent({ name: 'SchedulingResourceFilter' });
    expect(filter.props('resources').map(item => item.id)).toEqual([3]);
    await filter.get('button').trigger('click');
    await filter
      .get('button[data-label="SCHEDULING.GENERAL.SELECT_ALL"]')
      .trigger('click');
    await flushPromises();

    expect(mocks.calendar.setSelectedResources).toHaveBeenLastCalledWith([3]);
    expect(mocks.calendar.fetchCalendar).toHaveBeenCalled();
    expect(mocks.references.resources[1].customAttributes).toEqual({
      deleted_from_scheduling: true,
    });
  });

  it('autofills the selected service duration and preserves a manual interval on service change', async () => {
    mocks.references.services = durationServices;
    mocks.references.activeServices = durationServices;
    const { store } = await mountPage();
    const services = wrapper.findComponent({ name: 'TagMultiSelectComboBox' });
    services.vm.$emit('update:modelValue', [5]);
    await flushPromises();
    const duration = wrapper.get(
      'input[data-label="SCHEDULING.APPOINTMENT_FORM.DURATION_MIN"]'
    );
    expect(duration.element.value).toBe('75');
    expect(store.form.endsAt).toBe('2026-10-10T11:15');
    expect(store.form.serviceAmount).toBe(15000);
    expect(store.form.durationEdited).toBe(false);

    await duration.setValue('90');
    services.vm.$emit('update:modelValue', [6]);
    await flushPromises();
    expect(duration.element.value).toBe('90');
    expect(store.form.endsAt).toBe('2026-10-10T11:30');
    expect(store.form.serviceAmount).toBe(5000);
    expect(store.form.durationEdited).toBe(true);
  });

  it.each([
    ['STARTS_AT', '2026-10-10T10:15', '2026-10-10T11:30', 75],
    ['ENDS_AT', '2026-10-10T11:30', '2026-10-10T11:30', 90],
  ])(
    'preserves an explicitly edited %s across service changes',
    async (field, value, endsAt, durationMin) => {
      mocks.references.services = durationServices;
      mocks.references.activeServices = durationServices;
      const { store } = await mountPage();
      const services = wrapper.findComponent({
        name: 'TagMultiSelectComboBox',
      });
      services.vm.$emit('update:modelValue', [5]);
      await flushPromises();
      const date = wrapper
        .findAllComponents(SchedulingDateTimeField)
        .find(
          component =>
            component.props('label') === `SCHEDULING.APPOINTMENT_FORM.${field}`
        );
      date.vm.$emit('update:modelValue', value);
      await flushPromises();
      services.vm.$emit('update:modelValue', [6]);
      await flushPromises();

      expect(Number(store.form.durationMin)).toBe(durationMin);
      expect(store.form.endsAt).toBe(endsAt);
      expect(store.form.durationEdited).toBe(true);
    }
  );

  it('retains a dragged range when selecting a service', async () => {
    mocks.references.services = durationServices;
    mocks.references.activeServices = durationServices;
    const { store } = await mountPage({
      ...slot,
      endsAt: '2026-10-10T05:45:00Z',
      durationEdited: true,
    });
    wrapper
      .findComponent({ name: 'TagMultiSelectComboBox' })
      .vm.$emit('update:modelValue', [5]);
    await flushPromises();

    expect(store.form.endsAt).toBe('2026-10-10T10:45');
    expect(store.form.serviceAmount).toBe(15000);
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
    await vi.waitFor(
      () => expect(wrapper.find('.modal-mask').exists()).toBe(false),
      { timeout: 1000, interval: 20 }
    );
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

  it.each([
    ['DEAL_STAGE_REQUIRES_FIELDS', 'SAVED_WITHOUT_DEAL_REQUIRED_FIELDS'],
    ['CRM_DEAL_SELECTION_REQUIRED', 'SAVED_WITHOUT_DEAL'],
  ])(
    'closes a successfully saved booking and explains unlinked CRM result %s without resubmitting',
    async (code, messageKey) => {
      const { store } = await mountPage();
      SchedulingAppointmentsAPI.create.mockResolvedValueOnce({
        data: {
          payload: {
            id: 501,
            contact_id: 42,
            starts_at: slot.startsAt,
            ends_at: slot.endsAt,
            crm_deal_id: null,
            crm_link_result: { status: 'not_linked', code },
          },
        },
      });
      await wrapper
        .get('.modal-mask button[data-label="SCHEDULING.GENERAL.CREATE"]')
        .trigger('click');
      await flushPromises();

      expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledOnce();
      expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();
      expect(store.isOpen).toBe(false);
      expect(store.ui.error).toBeNull();
      expect(mocks.calendar.syncAppointment).toHaveBeenCalledOnce();
      expect(mocks.calendar.syncAppointment).toHaveBeenCalledWith(
        expect.objectContaining({
          id: 501,
          crmDealId: null,
          crmLinkResult: { status: 'not_linked', code },
        })
      );
      expect(mocks.alert).toHaveBeenCalledOnce();
      expect(mocks.alert).toHaveBeenCalledWith(
        `SCHEDULING.APPOINTMENT_FORM.${messageKey}`
      );
    }
  );

  it('retains the saved linkage warning when reopening a local booking and hides provider fields', async () => {
    const { store } = await mountPage();
    mocks.route.params.appointmentId = '501';
    store.openEdit({
      id: 501,
      accountId: 74,
      contactId: 42,
      clientFirstName: 'Client',
      resourceId: 3,
      startsAt: slot.startsAt,
      endsAt: slot.endsAt,
      crmLinkResult: {
        status: 'not_linked',
        code: 'DEAL_STAGE_REQUIRES_FIELDS',
      },
    });
    await flushPromises();
    expect(wrapper.get('[data-test="calendar-crm-link-result"]').text()).toBe(
      'SCHEDULING.APPOINTMENT_FORM.SAVED_WITHOUT_DEAL_REQUIRED_FIELDS'
    );
    expect(
      wrapper
        .find('[data-test="calendar-appointment-medelement-meta"]')
        .exists()
    ).toBe(false);
    expect(
      wrapper.find('[data-test="calendar-patient-provider-source"]').exists()
    ).toBe(false);
    expect(
      wrapper
        .findAllComponents(SelectStub)
        .some(field => field.props('label') === 'SCHEDULING.MEDELEMENT.CABINET')
    ).toBe(false);
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();

    store.openEdit({
      id: 502,
      accountId: 74,
      contactId: 42,
      clientFirstName: 'Client',
      resourceId: 3,
      startsAt: slot.startsAt,
      endsAt: slot.endsAt,
      source: 'medelement',
      medelementReceptionCode: 'me-902',
      providerConfirmationStatus: 'succeeded',
    });
    await flushPromises();
    const medelementMeta = wrapper.get(
      '[data-test="calendar-appointment-medelement-meta"]'
    );
    expect(medelementMeta.attributes('data-sync-state')).toBe('synced');
    expect(medelementMeta.find('svg').exists()).toBe(true);
    expect(medelementMeta.text()).toContain(
      'SCHEDULING.MEDELEMENT.SYNC_STATUS.SYNCED'
    );
    expect(medelementMeta.text()).not.toContain('me-902');

    const customFieldsSections = wrapper.findAllComponents(
      CrmCustomFieldsSection
    );
    expect(customFieldsSections).toHaveLength(1);
    expect(customFieldsSections[0].props('layout')).toBe('rows');
    expect(customFieldsSections[0].props('title')).toBe('');

    const receptionCodeInput = wrapper.get(
      'input[data-field-key="medelement_reception_code"]'
    );
    expect(receptionCodeInput.element.value).toBe('me-902');
    expect(receptionCodeInput.element.disabled).toBe(true);
    await receptionCodeInput.setValue('tampered-code');
    expect(
      store.form.customAttributes.medelement_reception_code
    ).toBeUndefined();

    const commentTextarea = wrapper.get(
      'textarea[data-label="SCHEDULING.APPOINTMENT_FORM.COMMENT"]'
    );
    expect(
      receptionCodeInput.element.compareDocumentPosition(
        commentTextarea.element
      )
    ).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(
      wrapper.get('[data-test="calendar-patient-provider-source"]').text()
    ).not.toContain('SCHEDULING.PATIENT_CONTEXT.PROVIDER_IDENTITY_READ_ONLY');
    expect(
      wrapper
        .find('button[data-label="SCHEDULING.PATIENT_CONTEXT.OPEN_DIALOG"]')
        .exists()
    ).toBe(false);

    const saveButton = wrapper.get(
      'button[data-label="SCHEDULING.GENERAL.UPDATE"]'
    );
    expect(saveButton.element.disabled).toBe(false);
    await commentTextarea.setValue('Внутренняя заметка по приёму');
    SchedulingAppointmentsAPI.update.mockResolvedValueOnce({
      data: {
        payload: {
          id: 502,
          account_id: 74,
          contact_id: 42,
          client_first_name: 'Client',
          client_comment: 'Внутренняя заметка по приёму',
          resource_id: 3,
          starts_at: slot.startsAt,
          ends_at: slot.endsAt,
          source: 'medelement',
          medelement_reception_code: 'me-902',
          provider_confirmation_status: 'succeeded',
        },
      },
    });
    expect(
      wrapper.get('select[data-label="SCHEDULING.APPOINTMENT_FORM.RESOURCE"]')
        .element.disabled
    ).toBe(true);
    expect(
      wrapper.get('select[data-label="SCHEDULING.APPOINTMENT_FORM.STATUS"]')
        .element.disabled
    ).toBe(true);
    expect(
      wrapper.get(
        'input[data-label="SCHEDULING.APPOINTMENT_FORM.SERVICE_AMOUNT"]'
      ).element.disabled
    ).toBe(true);

    await saveButton.trigger('click');
    await flushPromises();
    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(502, {
      client_comment: 'Внутренняя заметка по приёму',
      custom_attributes: {},
    });

    store.openEdit({
      id: 502,
      accountId: 74,
      contactId: 42,
      clientFirstName: 'Client',
      resourceId: 3,
      startsAt: slot.startsAt,
      endsAt: slot.endsAt,
      source: 'medelement',
      medelementReceptionCode: 'me-902',
      providerConfirmationStatus: 'succeeded',
      customAttributes: { medelement_cabinet_code: 'cab-1' },
    });
    await flushPromises();
    store.updateField('startsAt', '2026-10-10T11:00');
    await flushPromises();
    SchedulingAppointmentsAPI.update.mockResolvedValueOnce({
      data: {
        payload: {
          id: 502,
          account_id: 74,
          contact_id: 42,
          client_first_name: 'Client',
          resource_id: 3,
          starts_at: slot.startsAt,
          ends_at: slot.endsAt,
          source: 'medelement',
          medelement_reception_code: 'me-902',
          provider_confirmation_status: 'succeeded',
          custom_attributes: { medelement_cabinet_code: 'cab-1' },
        },
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValueOnce({
      data: { payload: [] },
    });
    SchedulingProviderCommandsAPI.create.mockResolvedValueOnce({
      data: {
        payload: {
          id: 901,
          status: 'succeeded',
          operation: 'move_reception',
        },
      },
    });
    await saveButton.trigger('click');
    await flushPromises();
    expect(SchedulingProviderCommandsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        appointment_id: 502,
        company_cabinet_code: 'cab-1',
        desired_starts_at: '2026-10-10T06:00:00.000Z',
        desired_ends_at: '2026-10-10T06:30:00.000Z',
        operation: 'move_reception',
        provider: 'medelement',
      })
    );

    store.openEdit({
      id: 503,
      accountId: 74,
      contactId: 42,
      clientFirstName: 'Client',
      resourceId: 3,
      startsAt: slot.startsAt,
      endsAt: slot.endsAt,
      status: 'cancelled',
      externalRef: null,
      providerConfirmationStatus: 'not_requested',
      customAttributes: {
        medelement_local_cancellation: { reception_code: 'me-903' },
      },
    });
    await flushPromises();
    const cancelledMeta = wrapper.get(
      '[data-test="calendar-appointment-medelement-meta"]'
    );
    expect(cancelledMeta.attributes('data-sync-state')).toBe('warning');
    expect(cancelledMeta.find('svg').exists()).toBe(true);
    expect(
      wrapper.get('input[data-field-key="medelement_reception_code"]').element
        .value
    ).toBe('me-903');
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
    await vi.waitFor(
      () => expect(wrapper.find('.modal-mask').exists()).toBe(false),
      { timeout: 1000, interval: 20 }
    );
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

  it('opens an existing appointment in the full editable card immediately and navigates to its dedicated appointment page', async () => {
    await mountPage();
    mocks.router.push.mockImplementationOnce(target => {
      if (target?.params?.appointmentId) {
        mocks.route.params.appointmentId = String(target.params.appointmentId);
      }
    });
    const grid = wrapper.findComponent({ name: 'SchedulingCalendarGrid' });
    // eslint-disable-next-line vue/custom-event-name-casing -- Preserve the existing calendar grid event contract.
    grid.vm.$emit('select-appointment', {
      id: 505,
      accountId: 74,
      contactId: 42,
      clientFirstName: 'Client',
      clientLastName: 'Patient',
      clientPhone: '+77001234567',
      clientComment: 'Follow-up check',
      resourceId: 3,
      startsAt: slot.startsAt,
      endsAt: slot.endsAt,
      status: 'confirmed',
    });
    await flushPromises();

    expect(
      wrapper.find('[data-test="calendar-appointment-compact-view"]').exists()
    ).toBe(false);
    expect(wrapper.find('.modal-mask').exists()).toBe(false);
    expect(
      wrapper.get('textarea[data-label="SCHEDULING.APPOINTMENT_FORM.COMMENT"]')
        .element.value
    ).toBe('Follow-up check');
    expect(
      wrapper.find('[data-test="calendar-patient-summary"]').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('button[data-label="SCHEDULING.CONTACT.SAVE_ACTION"]')
        .exists()
    ).toBe(false);
    const editContactBtn = wrapper.get(
      '[data-test="calendar-edit-contact-button"]'
    );
    await editContactBtn.trigger('click');
    await flushPromises();
    expect(
      wrapper
        .find('button[data-label="SCHEDULING.CONTACT.SAVE_ACTION"]')
        .exists()
    ).toBe(true);
    expect(mocks.router.push).toHaveBeenCalledWith({
      name: 'scheduling_appointment_show',
      params: { accountId: '74', appointmentId: 505 },
      query: {},
    });
  });

  it('loads a dedicated appointment page by route param with an inline conversation panel and returns to the calendar on close', async () => {
    mocks.route = reactive({
      params: { accountId: '74', appointmentId: '505' },
      query: {},
    });
    SchedulingAppointmentsAPI.show.mockResolvedValueOnce({
      data: {
        payload: {
          id: 505,
          account_id: 74,
          contact_id: 42,
          conversation_id: 777,
          conversation_display_id: 88,
          client_first_name: 'Client',
          client_last_name: 'Patient',
          client_phone: '+77001234567',
          client_comment: 'Dedicated page comment',
          resource_id: 3,
          starts_at: slot.startsAt,
          ends_at: slot.endsAt,
          status: 'confirmed',
        },
      },
    });

    const pinia = createPinia();
    const vuex = createStore({
      getters: { getCurrentUser: () => ({ id: 9 }) },
    });
    setActivePinia(pinia);
    wrapper = mount(SchedulingCalendarPage, {
      global: {
        plugins: [pinia, vuex],
        stubs,
        mocks: { $t: key => key },
      },
    });
    await flushPromises();

    expect(SchedulingAppointmentsAPI.show).toHaveBeenCalledWith(505);
    expect(mocks.calendar.fetchCalendar).not.toHaveBeenCalled();
    expect(wrapper.find('.modal-mask').exists()).toBe(false);
    expect(
      wrapper.find('[data-testid="scheduling-appointment-card"]').exists()
    ).toBe(true);
    expect(
      wrapper.get('textarea[data-label="SCHEDULING.APPOINTMENT_FORM.COMMENT"]')
        .element.value
    ).toBe('Dedicated page comment');

    const chatPanel = wrapper.findComponent({
      name: 'CrmDealConversationPanel',
    });
    expect(chatPanel.exists()).toBe(true);
    expect(chatPanel.props('inline')).toBe(true);
    expect(chatPanel.props('visible')).toBe(true);
    expect(chatPanel.props('conversationDisplayId')).toBe('88');

    await wrapper
      .get('button[data-label="SCHEDULING.GENERAL.BACK"]')
      .trigger('click');
    expect(mocks.router.push).toHaveBeenCalledWith({
      name: 'scheduling_calendar',
      params: { accountId: '74' },
      query: {},
    });
  });

  it('resets the appointment form on unmount and never renders an existing appointment in the popup modal when returning to the calendar', async () => {
    mocks.route = reactive({
      params: { accountId: '74', appointmentId: '505' },
      query: {},
    });
    SchedulingAppointmentsAPI.show.mockResolvedValueOnce({
      data: {
        payload: {
          id: 505,
          account_id: 74,
          contact_id: 42,
          client_first_name: 'Client',
          client_last_name: 'Patient',
          client_phone: '+77001234567',
          resource_id: 3,
          starts_at: slot.startsAt,
          ends_at: slot.endsAt,
          status: 'confirmed',
        },
      },
    });

    const pinia = createPinia();
    const vuex = createStore({
      getters: { getCurrentUser: () => ({ id: 9 }) },
    });
    setActivePinia(pinia);
    wrapper = mount(SchedulingCalendarPage, {
      global: {
        plugins: [pinia, vuex],
        stubs,
        mocks: { $t: key => key },
      },
    });
    await flushPromises();

    const store = useSchedulingAppointmentFormStore();
    expect(store.isOpen).toBe(true);
    expect(store.mode).toBe('edit');

    // Simulate navigating away to another section (e.g. Deals) and back to Calendar
    wrapper.unmount();
    expect(store.isOpen).toBe(false);
    expect(store.recordId).toBeNull();

    mocks.route = reactive({
      params: { accountId: '74' },
      query: {},
    });
    wrapper = mount(SchedulingCalendarPage, {
      global: {
        plugins: [pinia, vuex],
        stubs,
        mocks: { $t: key => key },
      },
    });
    await flushPromises();

    expect(store.isOpen).toBe(false);
    expect(wrapper.find('.modal-mask').exists()).toBe(false);
    expect(
      wrapper.find('[data-testid="scheduling-appointment-card"]').exists()
    ).toBe(false);
  });
});
