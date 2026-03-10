import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useSchedulingKassaStore } from './kassa';

const {
  addPaymentMock,
  appointmentsGetMock,
  cancelPaymentsMock,
  expensesGetMock,
  payAllMock,
  payMock,
  paymentsGetMock,
} = vi.hoisted(() => ({
  addPaymentMock: vi.fn(),
  appointmentsGetMock: vi.fn(),
  cancelPaymentsMock: vi.fn(),
  expensesGetMock: vi.fn(),
  payAllMock: vi.fn(),
  payMock: vi.fn(),
  paymentsGetMock: vi.fn(),
}));

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    get: appointmentsGetMock,
  },
}));

vi.mock('dashboard/api/scheduling/expenses', () => ({
  default: {
    get: expensesGetMock,
    pay: payMock,
    payAll: payAllMock,
  },
}));

vi.mock('dashboard/api/scheduling/payments', () => ({
  default: {
    addPayment: addPaymentMock,
    cancelPayments: cancelPaymentsMock,
    get: paymentsGetMock,
  },
}));

describe('useSchedulingKassaStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    addPaymentMock.mockReset();
    appointmentsGetMock.mockReset();
    cancelPaymentsMock.mockReset();
    expensesGetMock.mockReset();
    payAllMock.mockReset();
    payMock.mockReset();
    paymentsGetMock.mockReset();
  });

  it('builds finance query params from the selected filters', () => {
    const store = useSchedulingKassaStore();

    store.updateFilters({
      from: '2026-03-01',
      paymentKinds: ['payment', 'prepaid'],
      paymentMethods: ['cash'],
      resourceIds: [5, 8],
      status: ['paid'],
      to: '2026-03-31',
    });

    expect(store.buildQueryParams()).toEqual({
      from: expect.any(String),
      payment_kinds: 'payment,prepaid',
      payment_methods: 'cash',
      resource_ids: '5,8',
      status: 'paid',
      to: expect.any(String),
    });
    expect(store.buildQueryParams().from).toContain('2026-03-01T');
    expect(store.buildQueryParams().to).toContain('2026-03-31T');
  });

  it('loads payments, expenses, and appointment candidates together', async () => {
    paymentsGetMock.mockResolvedValue({
      data: {
        payload: [
          {
            amount: 10000,
            appointment_id: 41,
            created_at: '2026-03-09T04:10:00.000Z',
            id: 1,
          },
        ],
      },
    });
    expensesGetMock.mockResolvedValue({
      data: {
        payload: [
          {
            amount: 4000,
            appointment_id: 41,
            id: 11,
            status: 'unpaid',
          },
        ],
      },
    });
    appointmentsGetMock.mockResolvedValue({
      data: {
        payload: [
          {
            client_name: 'Amina',
            id: 41,
            resource_id: 7,
            service_name_snapshot: 'Consultation',
            starts_at: '2026-03-09T05:00:00.000Z',
          },
        ],
      },
    });

    const store = useSchedulingKassaStore();
    store.updateFilters({
      paymentKinds: ['payment'],
      paymentMethods: ['cash'],
      resourceIds: [7],
      status: ['unpaid'],
    });

    await store.loadAll();

    expect(paymentsGetMock).toHaveBeenCalledWith(
      expect.objectContaining({
        payment_kinds: 'payment',
        payment_methods: 'cash',
        resource_ids: '7',
        status: 'unpaid',
      })
    );
    expect(appointmentsGetMock).toHaveBeenCalledWith(
      expect.objectContaining({
        payment_status: 'awaiting_payment,prepaid,paid',
        resource_ids: '7',
        status: 'scheduled,confirmed,completed',
      })
    );
    expect(store.decoratedPayments[0].appointment.clientName).toBe('Amina');
    expect(store.decoratedExpenses[0].appointment.serviceNameSnapshot).toBe(
      'Consultation'
    );
    expect(store.paymentTotal).toBe(10000);
    expect(store.expenseTotals.unpaid).toBe(4000);
  });

  it('runs payAll against the filtered window and reloads the journals', async () => {
    paymentsGetMock.mockResolvedValue({ data: { payload: [] } });
    expensesGetMock.mockResolvedValue({ data: { payload: [] } });
    appointmentsGetMock.mockResolvedValue({ data: { payload: [] } });
    payAllMock.mockResolvedValue({ data: { payload: [] } });

    const store = useSchedulingKassaStore();
    store.updateFilters({
      from: '2026-03-01',
      resourceIds: [3],
      to: '2026-03-15',
    });

    await store.payAll();

    expect(payAllMock).toHaveBeenCalledWith({
      from: expect.any(String),
      resource_ids: '3',
      to: expect.any(String),
    });
    expect(paymentsGetMock).toHaveBeenCalledTimes(1);
    expect(expensesGetMock).toHaveBeenCalledTimes(1);
    expect(appointmentsGetMock).toHaveBeenCalledTimes(1);
  });
});
