import { shallowMount, flushPromises } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingConversationAppointmentsSidebar from './SchedulingConversationAppointmentsSidebar.vue';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';

const existingAppointment = {
  id: 501,
  clientFirstName: 'Айша',
  clientName: 'Айша',
  contactId: 42,
  conversationId: 123,
  endsAt: '2026-06-27T10:30:00.000Z',
  resourceId: 7,
  serviceAmount: 5000,
  serviceId: 9,
  serviceNameSnapshot: 'Консультация',
  startsAt: '2026-06-27T10:00:00.000Z',
  status: 'confirmed',
};

// Form times are the clinic wall clock (Asia/Almaty, UTC+5 all year), like
// the calendar grid; this is the instant they are saved as.
const clinicIso = wallClock => new Date(`${wallClock}:00+05:00`).toISOString();

const manualReviewCommand = {
  id: 55,
  operation: 'create_reception',
  status: 'provider_status_unknown',
  manual_cancellation_available: true,
  manual_cancellation_reception_code: 'created-1',
};

const verifiedCancellationResponse = () => ({
  data: {
    payload: {
      id: 55,
      status: 'cancelled',
      manual_cancellation_resolution: {
        result: 'removed',
        reception_code: 'created-1',
      },
      appointment: { ...existingAppointment, status: 'cancelled' },
    },
  },
});

const deferredRequest = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  dispatch: vi.fn(),
  loadResources: vi.fn(() => Promise.resolve()),
  loadServices: vi.fn(() => Promise.resolve()),
  resources: [
    {
      active: true,
      id: 7,
      name: 'Дина',
      slotDurationMin: 30,
      specialty: 'Стилист',
    },
  ],
  services: [
    {
      active: true,
      basePrice: 5000,
      durationMin: 30,
      id: 9,
      name: 'Консультация',
      prices: [],
    },
  ],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'ru' },
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
}));

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    create: vi.fn(() =>
      Promise.resolve({
        data: { payload: { ...existingAppointment, id: 777 } },
      })
    ),
    get: vi.fn(() =>
      Promise.resolve({ data: { payload: [existingAppointment] } })
    ),
    update: vi.fn(() =>
      Promise.resolve({
        data: { payload: { ...existingAppointment, client_name: 'Айша' } },
      })
    ),
    cancel: vi.fn(() =>
      Promise.resolve({
        data: {
          payload: {
            ...existingAppointment,
            medelement_provider_sync_status: 'pending',
          },
        },
      })
    ),
  },
}));

vi.mock('dashboard/api/scheduling/providerCommands', () => ({
  default: {
    list: vi.fn(),
    reconcile: vi.fn(),
    resolveCancellation: vi.fn(),
  },
}));

vi.mock('dashboard/stores/scheduling/references', () => ({
  useSchedulingReferencesStore: () => ({
    activeResources: mocks.resources,
    activeServices: mocks.services,
    loadResources: mocks.loadResources,
    loadServices: mocks.loadServices,
    resources: mocks.resources,
    services: mocks.services,
  }),
}));

const defaultCurrentChat = () => ({
  id: 123,
  meta: {
    sender: {
      id: 42,
      name: 'Айша',
      phone_number: 'test-phone-4567',
    },
  },
});

const mountComponent = (currentChat = defaultCurrentChat()) =>
  shallowMount(SchedulingConversationAppointmentsSidebar, {
    props: {
      currentChat,
    },
    global: {
      stubs: {
        SidebarActionsHeader: {
          name: 'SidebarActionsHeader',
          props: ['buttons'],
          emits: ['click', 'close'],
          template:
            '<button type="button" @click="$emit(\'click\', buttons[0].key)" />',
        },
        Spinner: true,
      },
    },
  });

describe('SchedulingConversationAppointmentsSidebar', () => {
  const openManualReview = async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [manualReviewCommand] },
    });
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    return wrapper;
  };

  beforeEach(() => {
    mocks.resources.splice(0, mocks.resources.length, {
      active: true,
      id: 7,
      name: 'Дина',
      slotDurationMin: 30,
      specialty: 'Стилист',
    });
    mocks.services.splice(0, mocks.services.length, {
      active: true,
      basePrice: 5000,
      durationMin: 30,
      id: 9,
      name: 'Консультация',
      prices: [],
    });
    mocks.alert.mockClear();
    mocks.dispatch.mockClear();
    mocks.loadResources.mockClear();
    mocks.loadServices.mockClear();
    SchedulingAppointmentsAPI.create.mockClear();
    SchedulingAppointmentsAPI.get.mockClear();
    SchedulingAppointmentsAPI.update.mockClear();
    SchedulingAppointmentsAPI.cancel.mockClear();
    SchedulingProviderCommandsAPI.list.mockReset();
    SchedulingProviderCommandsAPI.reconcile.mockReset();
    SchedulingProviderCommandsAPI.resolveCancellation.mockReset();
    SchedulingProviderCommandsAPI.resolveCancellation.mockResolvedValue(
      verifiedCancellationResponse()
    );
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [] },
    });
    SchedulingProviderCommandsAPI.reconcile.mockResolvedValue({
      data: { payload: {} },
    });
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [existingAppointment] },
    });
  });

  it('opens the new appointment form inline from the header plus button', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const header = wrapper.findComponent({ name: 'SidebarActionsHeader' });
    expect(header.props('buttons')).toEqual([
      expect.objectContaining({
        icon: 'i-lucide-plus',
        key: 'new_appointment',
      }),
    ]);

    await header.vm.$emit('click', 'new_appointment');

    const html = wrapper.html();
    expect(html).toContain('i-lucide-calendar-plus');
    expect(html).not.toContain('appointment-status-dashed-rail');
    expect(
      wrapper.find('#scheduling-conversation-appointment-status').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-first-name')
        .exists()
    ).toBe(true);
    expect(wrapper.vm.createForm.status).toBe('scheduled');
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'scheduled')
    ).toMatchObject({
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.scheduled',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'completed')
    ).toMatchObject({
      iconClass: '',
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed',
      labelClass: '',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'confirmed')
    ).toMatchObject({
      iconClass: 'text-n-teal-11',
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed',
      labelClass: 'text-n-teal-11',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'scheduled')
    ).toMatchObject({
      iconClass: 'text-n-amber-11',
      labelClass: 'text-n-amber-11',
    });
  });

  it('splits a two-part chat contact name when the surname field is empty', async () => {
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.name = 'Айжан Касымова';
    const wrapper = mountComponent(currentChat);
    await flushPromises();

    const header = wrapper.findComponent({ name: 'SidebarActionsHeader' });
    await header.vm.$emit('click', 'new_appointment');

    expect(wrapper.vm.createForm).toMatchObject({
      clientFirstName: 'Айжан',
      clientLastName: 'Касымова',
    });
  });

  it('renders appointment status as a colored icon before the title without a dashed status rail', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const html = wrapper.html();
    expect(html).toContain('i-lucide-badge-check');
    expect(html).toContain('text-n-teal-11');
    expect(html).not.toContain('appointment-status-dashed-rail');
    expect(html.indexOf('i-lucide-badge-check')).toBeLessThan(
      html.indexOf('Айша')
    );
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'completed')
    ).toMatchObject(
      expect.objectContaining({
        iconClass: '',
        labelClass: '',
      })
    );
  });

  it('opens an existing appointment as an edit form immediately', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-first-name-501')
        .exists()
    ).toBe(true);
    expect(wrapper.vm.openAppointmentKeys).toEqual(['appointment-501']);
    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      clientFirstName: 'Айша',
      resourceId: 7,
      serviceId: 9,
      status: 'confirmed',
    });
  });

  it('does not promote an unchanged legacy display name to structured identity', async () => {
    const legacyAppointment = {
      ...existingAppointment,
      clientFirstName: null,
      clientLastName: null,
      clientMiddleName: null,
      clientName: 'Касымова Айжан Ерлановна',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [legacyAppointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      clientFirstName: 'Касымова Айжан Ерлановна',
      clientLastName: '',
      clientMiddleName: '',
      clientNameStructured: false,
    });

    await wrapper.vm.saveAppointment(legacyAppointment);

    const payload = SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1];
    expect(payload.client_name).toBe('Касымова Айжан Ерлановна');
    expect(payload).not.toHaveProperty('client_first_name');
    expect(payload).not.toHaveProperty('client_last_name');
    expect(payload).not.toHaveProperty('client_middle_name');
  });

  it('shows and edits appointment times on the clinic clock', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    // 10:00Z is 15:00 in the clinic, whatever the browser timezone is.
    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      endsAt: '2026-06-27T15:30',
      startsAt: '2026-06-27T15:00',
    });
    expect(wrapper.vm.appointmentMeta(existingAppointment)).toContain('15:00');
    expect(wrapper.vm.appointmentMeta(existingAppointment)).toContain('15:30');

    // The 30 minute service moves the end on the clinic clock, across
    // midnight too.
    const form = wrapper.vm.appointmentForms['appointment-501'];
    form.startsAt = '2026-06-27T23:45';
    wrapper.vm.updateFormEndFromDuration(form);
    expect(form.endsAt).toBe('2026-06-28T00:15');

    await wrapper.vm.saveAppointment(existingAppointment);
    const payload = SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1];
    expect(payload).toMatchObject({
      ends_at: '2026-06-27T19:15:00.000Z',
      starts_at: '2026-06-27T18:45:00.000Z',
    });
  });

  it('updates an existing appointment from the inline edit form', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      clientFirstName: 'Айша updated',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T11:00',
      resourceId: 7,
      serviceAmount: '7000',
      serviceId: 9,
      startsAt: '2026-06-27T10:30',
      status: 'completed',
    });

    await wrapper.vm.saveAppointment(existingAppointment);

    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(501, {
      appointment_type: 'primary',
      client_first_name: 'Айша updated',
      client_last_name: null,
      client_middle_name: null,
      client_name: 'Айша updated',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_id: 123,
      ends_at: clinicIso('2026-06-27T11:00'),
      resource_id: 7,
      service_amount: 7000,
      service_id: 9,
      service_ids: [9],
      source: 'conversation',
      starts_at: clinicIso('2026-06-27T10:30'),
      status: 'completed',
    });
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('hydrates and sends the selected MedElement cabinet when editing a local appointment', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [
        { company_cabinet_code: '501', cabinet_name: 'Главный' },
      ],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const localMedelementAppointment = {
      ...existingAppointment,
      clientLastName: 'Касымова',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      customAttributes: { medelementCabinetCode: '501' },
      source: 'conversation',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [localMedelementAppointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.vm.appointmentForms['appointment-501'].medelementCabinetCode
    ).toBe('501');
    expect(
      wrapper
        .find('#scheduling-conversation-appointment-medelement-cabinet-501')
        .exists()
    ).toBe(true);

    await wrapper.vm.saveAppointment(localMedelementAppointment);

    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      501,
      expect.objectContaining({
        custom_attributes: { medelement_cabinet_code: '501' },
      })
    );
  });

  it('keeps provider-owned MedElement appointments read-only', async () => {
    const providerAppointment = {
      ...existingAppointment,
      source: 'medelement',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [providerAppointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.openAppointmentKeys).toEqual([]);
    expect(wrapper.find('section button').attributes('disabled')).toBeDefined();
    wrapper.vm.toggleAppointment(providerAppointment);
    await wrapper.vm.saveAppointment(providerAppointment);

    expect(wrapper.vm.openAppointmentKeys).toEqual([]);
    expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();

    SchedulingAppointmentsAPI.cancel.mockResolvedValueOnce({
      data: {
        payload: {
          ...providerAppointment,
          provider_confirmation_status: 'pending',
        },
      },
    });

    await wrapper.vm.cancelAppointment(providerAppointment);

    expect(SchedulingAppointmentsAPI.cancel).toHaveBeenCalledWith(501);
    expect(mocks.alert).toHaveBeenCalledWith('SCHEDULING.MEDELEMENT.QUEUED');
    expect(
      wrapper.vm.isProviderCancellationPending(wrapper.vm.appointments[0])
    ).toBe(true);
  });

  it('does not announce completed cancellation while MedElement is still pending', async () => {
    SchedulingAppointmentsAPI.cancel.mockResolvedValueOnce({
      data: {
        payload: {
          ...existingAppointment,
          status: 'cancelled',
          providerConfirmationStatus: 'pending',
        },
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.cancelAppointment(existingAppointment);

    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING'
    );
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'
    );
  });

  it('holds a local confirmed slot while its MedElement removal is pending', async () => {
    SchedulingAppointmentsAPI.cancel.mockResolvedValueOnce({
      data: {
        payload: {
          ...existingAppointment,
          status: 'scheduled',
          customAttributes: { medelement_cancellation_command_id: 42 },
          providerConfirmationStatus: 'pending',
        },
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.cancelAppointment(existingAppointment);

    expect(wrapper.vm.appointments[0].status).toBe('scheduled');
    expect(wrapper.text()).toContain(
      'Awaiting MedElement cancellation confirmation'
    );
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING'
    );
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'
    );
  });

  it('keeps an already cancelled unknown MedElement reception visibly in manual review', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            status: 'cancelled',
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'MedElement cancellation is not confirmed'
    );
    expect(wrapper.find('.text-n-ruby-11').exists()).toBe(true);
  });

  it('shows a remote candidate for manual resolution without deleting an already cancelled booking', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            status: 'cancelled',
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          {
            id: 55,
            operation: 'create_reception',
            status: 'provider_status_unknown',
            cancellation_review_candidates: ['created-1'],
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_CANDIDATES'
    );
  });

  it('shows the exact reception and instructions before manual cancellation verification', async () => {
    const wrapper = await openManualReview();

    expect(wrapper.find('[role="status"]').text()).toContain('created-1');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toEqual({
      commandId: 55,
      receptionCode: 'created-1',
    });
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
  });

  it('updates the appointment and clears review only after verified provider removal', async () => {
    const wrapper = await openManualReview();
    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);

    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).toHaveBeenCalledWith(55, {
      provider: 'medelement',
      receptionCode: 'created-1',
    });
    expect(wrapper.vm.appointments[0].status).toBe('cancelled');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeUndefined();
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
  });

  it('keeps the slot and review when the remote reception is still active', async () => {
    const wrapper = await openManualReview();
    SchedulingProviderCommandsAPI.resolveCancellation.mockRejectedValueOnce({
      response: {
        status: 409,
        data: {
          code: 'MEDELEMENT_CANCELLATION_NOT_VERIFIED',
          error: 'Removal is not verified',
        },
      },
    });

    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);

    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeDefined();
    expect(mocks.alert).toHaveBeenCalledWith('Removal is not verified');
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
  });

  it('does not announce cancellation for an incomplete server response', async () => {
    const wrapper = await openManualReview();
    SchedulingProviderCommandsAPI.resolveCancellation.mockResolvedValueOnce({
      data: { payload: { id: 55, status: 'cancelled' } },
    });

    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);

    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeDefined();
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
  });

  it('sends one readback for duplicate clicks and blocks a parallel booking check', async () => {
    const wrapper = await openManualReview();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.resolveCancellation.mockReturnValueOnce(
      request.promise
    );
    const verification = wrapper.vm.resolveManualCancellation(
      wrapper.vm.appointments[0]
    );

    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).toHaveBeenCalledTimes(1);
    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledTimes(1);

    request.resolve(verifiedCancellationResponse());
    await verification;
  });

  it('ignores late verification when switching away and back to the same chat', async () => {
    const wrapper = await openManualReview();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.resolveCancellation.mockReturnValueOnce(
      request.promise
    );
    const verification = wrapper.vm.resolveManualCancellation(
      wrapper.vm.appointments[0]
    );

    await wrapper.setProps({
      currentChat: { ...defaultCurrentChat(), id: 456 },
    });
    await wrapper.setProps({ currentChat: defaultCurrentChat() });
    await flushPromises();
    request.resolve(verifiedCancellationResponse());
    await verification;

    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews).toEqual({});
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });

  it('discards a command list received after the contact changes in the same chat', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.list.mockReturnValueOnce(request.promise);
    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );

    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.id = 99;
    await wrapper.setProps({ currentChat });
    request.resolve({ data: { payload: [manualReviewCommand] } });
    await checking;

    expect(wrapper.vm.cancellationReviews).toEqual({});
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(mocks.alert).not.toHaveBeenCalled();
  });

  it('can check the booking normally without resolving manual cancellation', async () => {
    const wrapper = await openManualReview();
    await wrapper.vm.checkReviewedBooking(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.reconcile).toHaveBeenCalledWith(55, {
      provider: 'medelement',
    });
    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).not.toHaveBeenCalled();
    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeUndefined();
  });

  it('shows a red review label for a local booking with an unknown MedElement result', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Not confirmed in MedElement');
    expect(wrapper.find('.text-n-ruby-11').exists()).toBe(true);
  });

  it('starts a read-only provider check without cancelling the local appointment', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          {
            id: 55,
            operation: 'create_reception',
            status: 'provider_status_unknown',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledWith({
      provider: 'medelement',
      appointmentId: 501,
      activeOnly: true,
    });
    expect(SchedulingProviderCommandsAPI.reconcile).toHaveBeenCalledWith(55, {
      provider: 'medelement',
    });
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CHECK_STARTED'
    );
  });

  it('asks for manual review when an unknown booking has no reconcilable command', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(existingAppointment);

    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CHECK_NOT_AVAILABLE'
    );
  });

  it('uses the cancellation endpoint instead of updating the record status', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    wrapper.vm.appointmentForms['appointment-501'].status = 'cancelled';

    await wrapper.vm.saveAppointment(existingAppointment);

    expect(SchedulingAppointmentsAPI.cancel).toHaveBeenCalledWith(501);
    expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();
  });

  it('uses the cabinet code as the edit option label when provider names are absent', async () => {
    mocks.resources.splice(0, mocks.resources.length, {
      id: 9,
      active: true,
      name: 'Doctor',
      customAttributes: {
        medelement_specialist_code: 'specialist-1',
        medelement_cabinets: [
          {
            company_cabinet_code: 'cabinet-1',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.vm.medelementCabinetOptionsForForm({ resourceId: 9 })
    ).toEqual([{ label: 'cabinet-1', value: 'cabinet-1' }]);
  });

  it('updates an existing appointment without stale service ids when no active services exist', async () => {
    mocks.services.splice(0, mocks.services.length, {
      active: false,
      basePrice: 5000,
      durationMin: 30,
      id: 9,
      name: 'Консультация',
      prices: [],
    });
    const wrapper = mountComponent();
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      serviceAmount: '7000',
    });

    await wrapper.vm.saveAppointment(existingAppointment);

    expect(wrapper.vm.hasServiceOptions).toBe(false);
    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      501,
      expect.objectContaining({
        service_amount: 7000,
        service_ids: [],
        service_name_snapshot: 'Консультация',
      })
    );
    expect(
      SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1]
    ).not.toHaveProperty('service_id');
  });

  it('updates a dialog appointment by conversation display id when the record is not linked to a database conversation id', async () => {
    const threadAppointment = {
      ...existingAppointment,
      conversationDisplayId: null,
      conversationId: null,
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [threadAppointment] },
    });
    const wrapper = mountComponent({
      active_reply_channel: { conversation_id: 659 },
      conversation_ids: [659],
      id: 22,
      is_communication_thread: true,
      meta: {
        sender: {
          id: 42,
          name: 'Айша',
          phone_number: 'test-phone-4567',
        },
      },
    });
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      clientFirstName: 'Айша updated',
      endsAt: '2026-06-27T11:00',
      resourceId: 7,
      serviceAmount: '7000',
      startsAt: '2026-06-27T10:30',
    });

    await wrapper.vm.saveAppointment(threadAppointment);

    const payload = SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1];
    expect(payload).toMatchObject({ conversation_display_id: 659 });
    expect(payload).not.toHaveProperty('conversation_id');
  });

  it('creates an appointment from the inline form with dialog context', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    Object.assign(wrapper.vm.createForm, {
      clientFirstName: 'Айша',
      clientLastName: 'Касымова',
      clientMiddleName: 'Ерлановна',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T10:30',
      resourceId: 7,
      serviceAmount: '5000',
      serviceId: 9,
      startsAt: '2026-06-27T10:00',
      status: 'completed',
    });

    await wrapper.vm.saveCreateAppointment();

    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith({
      appointment_type: 'primary',
      client_first_name: 'Айша',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна',
      client_name: 'Айша Касымова Ерлановна',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_display_id: 123,
      ends_at: clinicIso('2026-06-27T10:30'),
      resource_id: 7,
      service_amount: 5000,
      service_id: 9,
      service_ids: [9],
      source: 'conversation',
      starts_at: clinicIso('2026-06-27T10:00'),
      status: 'completed',
    });
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('requires MedElement patient identity but allows an appointment without a service', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [
        { company_cabinet_code: 'cabinet-1', cabinet_name: 'Кабинет 1' },
      ],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    expect(wrapper.vm.isCreateFormInvalid).toBe(true);
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();

    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Касымова',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
    });

    expect(wrapper.vm.createForm.medelementCabinetCode).toBe('cabinet-1');
    expect(wrapper.vm.isCreateFormInvalid).toBe(false);
  });

  it('requires a cabinet for a MedElement specialist and sends the selected cabinet', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [
        { company_cabinet_code: '501', cabinet_name: 'Главный' },
        {
          company_cabinet_code: '502',
          cabinet_name: 'Диагностика',
          cabinet_number: '2',
        },
      ],
      medelement_specialist_code: 'specialist-1',
    };
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-medelement-cabinet')
        .exists()
    ).toBe(true);
    expect(wrapper.vm.medelementCabinetOptions).toEqual([
      { label: 'Главный', value: '501' },
      { label: 'Диагностика · 2', value: '502' },
    ]);

    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Касымова',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
    });
    expect(wrapper.vm.isCreateFormInvalid).toBe(true);

    wrapper.vm.createForm.medelementCabinetCode = '502';
    await wrapper.vm.saveCreateAppointment();

    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        custom_attributes: { medelement_cabinet_code: '502' },
      })
    );
  });

  it('uses explicit service links for the selected MedElement specialist', async () => {
    mocks.resources[0].customAttributes = {
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services.splice(
      0,
      mocks.services.length,
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-9' },
        id: 9,
        name: 'Консультация',
        prices: [{ active: true, price: 5000, resourceId: 7 }],
      },
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-10' },
        id: 10,
        name: 'Другая услуга',
        prices: [{ active: true, price: 7000, resourceId: 8 }],
      },
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-11' },
        id: 11,
        name: 'Услуга без персональной цены',
        prices: [],
      },
      {
        active: true,
        customAttributes: {},
        id: 12,
        name: 'Локальная услуга',
        prices: [],
      }
    );
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.serviceOptionsForForm({ resourceId: 7 })).toEqual([
      { label: 'Консультация', value: 9, wrapLabel: true },
    ]);
  });

  it('shows the full mapped catalog when the MedElement specialist has no links', async () => {
    mocks.resources[0].customAttributes = {
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services.splice(
      0,
      mocks.services.length,
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-9' },
        id: 9,
        name: 'Консультация',
        prices: [],
      },
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-10' },
        id: 10,
        name: 'Другая услуга',
        prices: [{ active: true, price: 7000, resourceId: 8 }],
      },
      {
        active: true,
        customAttributes: {},
        id: 11,
        name: 'Локальная услуга',
        prices: [],
      }
    );
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.serviceOptionsForForm({ resourceId: 7 })).toEqual([
      { label: 'Консультация', value: 9, wrapLabel: true },
      { label: 'Другая услуга', value: 10, wrapLabel: true },
    ]);
  });

  it('uses a free service name field when there are no configured services', async () => {
    mocks.services.splice(0, mocks.services.length);
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.find('#scheduling-conversation-appointment-service').exists()
    ).toBe(true);
    expect(wrapper.vm.hasServiceOptions).toBe(false);

    Object.assign(wrapper.vm.createForm, {
      clientFirstName: 'Айша',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T10:30',
      resourceId: 7,
      serviceAmount: '3000',
      serviceNameSnapshot: 'Осмотр',
      startsAt: '2026-06-27T10:00',
    });

    await wrapper.vm.saveCreateAppointment();

    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith({
      appointment_type: 'primary',
      client_first_name: 'Айша',
      client_last_name: null,
      client_middle_name: null,
      client_name: 'Айша',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_display_id: 123,
      ends_at: clinicIso('2026-06-27T10:30'),
      resource_id: 7,
      service_amount: 3000,
      service_ids: [],
      service_name_snapshot: 'Осмотр',
      source: 'conversation',
      starts_at: clinicIso('2026-06-27T10:00'),
      status: 'scheduled',
    });
  });
  it('prefills a MedElement IIN, validates its length and sends it with the appointment', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.identifier = '940720300129';
    const wrapper = mountComponent(currentChat);
    await flushPromises();
    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    const iinField = wrapper.findComponent(
      '#scheduling-conversation-appointment-client-iin'
    );
    expect(iinField.exists()).toBe(true);
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');

    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Хамзаулы',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      endsAt: '2026-06-27T10:30',
      startsAt: '2026-06-27T10:00',
    });
    await iinField.vm.$emit('update:modelValue', '123');
    expect(wrapper.vm.isCreateFormInvalid).toBe(true);
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();

    await iinField.vm.$emit('update:modelValue', '940720300128');
    expect(wrapper.vm.isCreateFormInvalid).toBe(true);
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();

    await iinField.vm.$emit('update:modelValue', '940720300129');
    expect(wrapper.vm.isCreateFormInvalid).toBe(false);
    SchedulingAppointmentsAPI.create.mockImplementationOnce(payload =>
      Promise.resolve({
        data: {
          payload: {
            ...existingAppointment,
            id: 778,
            clientIdentifier: payload.client_identifier,
          },
        },
      })
    );
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({ client_identifier: '940720300129' })
    );
    expect(
      wrapper.vm.appointmentForms['appointment-778'].clientIdentifier
    ).toBe('940720300129');
  });

  it('shows and saves an IIN when editing a local MedElement appointment', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const appointment = {
      ...existingAppointment,
      clientFirstName: 'Асет',
      clientIdentifier: '940720300129',
      clientLastName: 'Хамзаулы',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      customAttributes: { medelementCabinetCode: '501' },
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [appointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-iin-501')
        .exists()
    ).toBe(true);
    expect(
      wrapper.vm.appointmentForms['appointment-501'].clientIdentifier
    ).toBe('940720300129');
    await wrapper.vm.saveAppointment(appointment);
    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      501,
      expect.objectContaining({
        client_first_name: 'Асет',
        client_identifier: '940720300129',
        client_last_name: 'Хамзаулы',
      })
    );
  });

  it('leaves a linked MedElement patient bookable without a locally known IIN', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.custom_attributes = {
      medelement_patient_code: 'patient-1',
    };
    const wrapper = mountComponent(currentChat);
    await flushPromises();
    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');
    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Хамзаулы',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      endsAt: '2026-06-27T10:30',
      startsAt: '2026-06-27T10:00',
    });

    expect(wrapper.vm.isCreateFormInvalid).toBe(false);
    await wrapper.vm.saveCreateAppointment();
    expect(
      SchedulingAppointmentsAPI.create.mock.calls.at(-1)[0]
    ).toHaveProperty('client_identifier', null);
  });

  it('does not prefill another contact appointment with the current chat IIN', async () => {
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.identifier = '940720300129';
    const appointment = {
      ...existingAppointment,
      clientIdentifier: null,
      contactId: 999,
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [appointment] },
    });

    const wrapper = mountComponent(currentChat);
    await flushPromises();
    expect(
      wrapper.vm.appointmentForms['appointment-501'].clientIdentifier
    ).toBe('');
  });

  it('ignores a stale appointment load after switching chats', async () => {
    const pending = [];
    const otherAppointment = {
      ...existingAppointment,
      id: 902,
      contactId: 77,
      conversationId: 999,
      clientName: 'Другой клиент',
    };
    SchedulingAppointmentsAPI.get.mockImplementation(params => {
      if (
        params.contact_ids === 42 ||
        params.conversation_display_ids === '123'
      ) {
        return new Promise(resolve => {
          pending.push(resolve);
        });
      }
      return Promise.resolve({ data: { payload: [otherAppointment] } });
    });

    const wrapper = mountComponent();
    await flushPromises();
    expect(pending).toHaveLength(2);

    await wrapper.setProps({
      currentChat: {
        id: 999,
        meta: { sender: { id: 77, name: 'Другой клиент' } },
      },
    });
    await flushPromises();
    expect(wrapper.vm.appointments.map(appointment => appointment.id)).toEqual([
      902,
    ]);

    pending.forEach(resolve =>
      resolve({ data: { payload: [existingAppointment] } })
    );
    await flushPromises();
    expect(wrapper.vm.appointments.map(appointment => appointment.id)).toEqual([
      902,
    ]);
    wrapper.unmount();
  });

  const prepareIinAppointment = async (appointment = {}, sender = {}) => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const chat = defaultCurrentChat();
    Object.assign(chat.meta.sender, sender);
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [{ ...existingAppointment, ...appointment }] },
    });
    const wrapper = mountComponent(chat);
    await flushPromises();
    return wrapper;
  };

  it('clears an inferred contact IIN when entering another patient name', async () => {
    const wrapper = await prepareIinAppointment(
      {},
      { identifier: '940720300129' }
    );
    await wrapper.vm.startCreateAppointment({ scroll: false });
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');
    wrapper.vm.updatePatientNamePart(
      wrapper.vm.createForm,
      'clientFirstName',
      'Другой'
    );
    expect(wrapper.vm.createForm.clientIdentifier).toBe('');
    expect(wrapper.vm.buildCreatePayload()).toHaveProperty(
      'client_identifier',
      null
    );
  });

  it('preserves an explicitly entered IIN while correcting patient name', async () => {
    const wrapper = await prepareIinAppointment(
      {},
      { identifier: '940720300129' }
    );
    await wrapper.vm.startCreateAppointment({ scroll: false });
    wrapper.vm.updatePatientIin(wrapper.vm.createForm, '940720300129');
    wrapper.vm.updatePatientNamePart(
      wrapper.vm.createForm,
      'clientLastName',
      'Исправленная'
    );
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');
  });

  it('does not infer an editing patient IIN from the same contact or shared phone', async () => {
    const wrapper = await prepareIinAppointment(
      {
        clientFirstName: 'Родственник',
        clientIdentifier: null,
        clientLastName: 'Пациент',
      },
      { identifier: '940720300129' }
    );
    expect(
      wrapper.vm.appointmentForms['appointment-501'].clientIdentifier
    ).toBe('');
  });

  it('sends explicit null when clearing a stored appointment IIN', async () => {
    const wrapper = await prepareIinAppointment({
      clientIdentifier: '940720300129',
      clientLastName: 'Пациент',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      customAttributes: { medelementCabinetCode: '501' },
    });
    const field = wrapper.findComponent(
      '#scheduling-conversation-appointment-client-iin-501'
    );
    await field.vm.$emit('update:modelValue', '');
    await wrapper.vm.saveAppointment(wrapper.vm.appointments[0]);
    expect(
      SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1]
    ).toHaveProperty('client_identifier', null);
  });

  it('shows an invalid stored identifier for correction without silently erasing it', async () => {
    const wrapper = await prepareIinAppointment({
      clientIdentifier: 'invalid-id',
    });
    const form = wrapper.vm.appointmentForms['appointment-501'];
    expect(form.clientIdentifier).toBe('invalid-id');
    expect(wrapper.vm.medelementIinError(form)).toBe(
      'SCHEDULING.CONTACT.IIN_ERROR_LENGTH'
    );
  });

  it('discards a previous chat load even after switching away and back', async () => {
    const pending = [deferredRequest(), deferredRequest()];
    SchedulingAppointmentsAPI.get
      .mockImplementationOnce(() => pending[0].promise)
      .mockImplementationOnce(() => pending[1].promise);
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.setProps({
      currentChat: { id: 999, meta: { sender: { id: 77 } } },
    });
    await flushPromises();
    await wrapper.setProps({ currentChat: defaultCurrentChat() });
    await flushPromises();
    pending.forEach(request =>
      request.resolve({
        data: { payload: [{ ...existingAppointment, clientName: 'Stale' }] },
      })
    );
    await flushPromises();
    expect(wrapper.vm.appointments[0].clientName).toBe('Айша');
    wrapper.unmount();
  });

  it('does not start an appointment load after unmounting during reference loading', async () => {
    const request = deferredRequest();
    mocks.loadResources.mockImplementationOnce(() => request.promise);
    const wrapper = mountComponent();
    await flushPromises();
    wrapper.unmount();
    request.resolve();
    await flushPromises();
    expect(SchedulingAppointmentsAPI.get).not.toHaveBeenCalled();
  });
});
