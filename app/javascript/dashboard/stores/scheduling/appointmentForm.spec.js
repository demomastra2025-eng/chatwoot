import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import { useSchedulingAppointmentFormStore } from './appointmentForm';

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    create: vi.fn(),
    createConversation: vi.fn(),
    delete: vi.fn(),
    update: vi.fn(),
  },
}));

vi.mock('dashboard/api/scheduling/contacts', () => ({
  default: {
    create: vi.fn(),
    get: vi.fn(),
    update: vi.fn(),
  },
}));

describe('useSchedulingAppointmentFormStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
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

  it('hydrates prepaid fields when editing an appointment', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      prepaidAmount: 5000,
      prepaidPaymentMethod: 'kaspi_qr',
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    expect(store.form.prepaidAmount).toBe(5000);
    expect(store.form.prepaidPaymentMethod).toBe('kaspi_qr');
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

  it('defaults prepaid payment method to cash when prepaid amount is positive', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openCreate();
    store.updateField('prepaidAmount', 4000);

    expect(store.form.prepaidPaymentMethod).toBe('cash');
    expect(store.buildPayload()).toMatchObject({
      prepaid_amount: 4000,
      prepaid_payment_method: 'cash',
    });
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

  it('clears prepaid payment method when prepaid amount is zeroed out', () => {
    const store = useSchedulingAppointmentFormStore();

    store.openEdit({
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 11,
      prepaidAmount: 5000,
      prepaidPaymentMethod: 'cash',
      resourceId: 3,
      serviceAmount: 20000,
      serviceId: 5,
      startsAt: '2026-03-09T10:00:00.000Z',
    });

    store.updateField('prepaidAmount', 0);

    expect(store.form.prepaidPaymentMethod).toBe('');
    expect(store.buildPayload()).toMatchObject({
      prepaid_amount: 0,
    });
    expect(store.buildPayload()).not.toHaveProperty('prepaid_payment_method');
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
