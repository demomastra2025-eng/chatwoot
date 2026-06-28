import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import { useSchedulingAppointmentFormStore } from './appointmentForm';

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    create: vi.fn(),
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
