import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { CALENDAR_STORAGE_KEY } from 'dashboard/routes/dashboard/scheduling/constants';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { useSchedulingCalendarStore } from './calendar';

const { showMock } = vi.hoisted(() => ({
  showMock: vi.fn(),
}));

vi.mock('dashboard/api/scheduling/calendar', () => ({
  default: {
    show: showMock,
  },
}));

describe('useSchedulingCalendarStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    window.localStorage.clear();
    showMock.mockReset();
  });

  it('hydrates saved preferences and requests the calendar payload with filters', async () => {
    window.localStorage.setItem(
      CALENDAR_STORAGE_KEY,
      JSON.stringify({
        anchorDate: '2026-03-09T00:00:00.000Z',
        currentView: 'day',
        selectedResourceIds: ['5', '8'],
      })
    );

    showMock.mockResolvedValue({
      data: {
        payload: {
          appointments: [],
          break_rules: [],
          expenses: [],
          holidays: [],
          payments: [],
          range: {
            from: '2026-03-08T18:00:00.000Z',
            to: '2026-03-09T17:59:59.999Z',
          },
          resources: [{ id: 5, name: 'Dr. Sam' }],
          slots: [],
          time_offs: [],
          work_rules: [],
          workday_overrides: [],
        },
      },
    });

    const store = useSchedulingCalendarStore();
    store.setStatusFilters(['confirmed']);
    store.setPaymentStatusFilters(['paid']);

    const payload = await store.fetchCalendar();

    expect(store.currentView).toBe('day');
    expect(store.anchorDate).toBe('2026-03-09T00:00:00.000Z');
    expect(store.selectedResourceIds).toEqual([5, 8]);
    expect(showMock).toHaveBeenCalledWith(
      expect.objectContaining({
        include_slots: true,
        payment_status: 'paid',
        resource_ids: '5,8',
        status: 'confirmed',
        view: 'day',
      })
    );
    expect(payload.resources).toEqual([{ id: 5, name: 'Dr. Sam' }]);
    expect(store.visibleResources).toEqual([{ id: 5, name: 'Dr. Sam' }]);
  });

  it('passes appointment custom field filters to the calendar request', async () => {
    showMock.mockResolvedValue({
      data: {
        payload: {
          appointments: [],
          break_rules: [],
          expenses: [],
          holidays: [],
          payments: [],
          range: {
            from: '2026-03-09T00:00:00.000Z',
            to: '2026-03-16T00:00:00.000Z',
          },
          resources: [],
          slots: [],
          time_offs: [],
          work_rules: [],
          workday_overrides: [],
        },
      },
    });

    const store = useSchedulingCalendarStore();
    store.setCustomAttributeFilters({
      notes: { operator: 'contains', value: 'follow-up' },
      needs_lab: [true],
      visit_reason: ['follow_up'],
    });

    await store.fetchCalendar();

    expect(showMock).toHaveBeenCalledWith(
      expect.objectContaining({
        custom_attribute_filters: {
          notes: { operator: 'contains', value: 'follow-up' },
          needs_lab: [true],
          visit_reason: ['follow_up'],
        },
      })
    );
  });

  it('does not expose all specialists when no resource is selected', () => {
    const store = useSchedulingCalendarStore();

    store.payload = {
      appointments: [],
      breakRules: [],
      expenses: [],
      holidays: [],
      payments: [],
      range: { from: null, to: null },
      resources: [
        { id: 5, name: 'Dr. Sam' },
        { id: 8, name: 'Dr. Lee' },
      ],
      slots: [],
      timeOffs: [],
      workRules: [],
      workdayOverrides: [],
    };

    expect(store.selectedResourceIds).toEqual([]);
    expect(store.visibleResources).toEqual([]);
  });

  it('merges updated appointment finance snapshots into the calendar payload', () => {
    const store = useSchedulingCalendarStore();

    store.payload = {
      appointments: [
        {
          id: 3,
          startsAt: '2026-03-11T08:00:00.000Z',
        },
      ],
      breakRules: [],
      expenses: [
        { appointmentId: 3, id: 201 },
        { appointmentId: 9, id: 202 },
      ],
      holidays: [],
      payments: [
        { appointmentId: 3, createdAt: '2026-03-11T08:05:00.000Z', id: 301 },
        { appointmentId: 9, createdAt: '2026-03-10T08:05:00.000Z', id: 302 },
      ],
      range: { from: null, to: null },
      resources: [],
      slots: [],
      timeOffs: [],
      workRules: [],
      workdayOverrides: [],
    };

    store.upsertAppointment({
      ends_at: '2026-03-11T09:00:00.000Z',
      expense: { appointment_id: 3, id: 401 },
      id: 3,
      payments: [
        {
          appointment_id: 3,
          created_at: '2026-03-11T08:30:00.000Z',
          id: 501,
        },
      ],
      starts_at: '2026-03-11T08:30:00.000Z',
    });

    expect(store.payload.appointments).toEqual([
      {
        endsAt: '2026-03-11T09:00:00.000Z',
        expense: { appointmentId: 3, id: 401 },
        id: 3,
        payments: [
          {
            appointmentId: 3,
            createdAt: '2026-03-11T08:30:00.000Z',
            id: 501,
          },
        ],
        startsAt: '2026-03-11T08:30:00.000Z',
      },
    ]);
    expect(store.payload.expenses).toEqual([
      { appointmentId: 3, id: 401 },
      { appointmentId: 9, id: 202 },
    ]);
    expect(store.payload.payments).toEqual([
      { appointmentId: 3, createdAt: '2026-03-11T08:30:00.000Z', id: 501 },
      { appointmentId: 9, createdAt: '2026-03-10T08:05:00.000Z', id: 302 },
    ]);
  });

  it('removes synced appointments that no longer match active filters', () => {
    const store = useSchedulingCalendarStore();
    store.currentView = 'week';
    store.anchorDate = '2026-03-09T00:00:00.000Z';
    store.selectedResourceIds = [5];
    store.statusFilters = ['confirmed'];
    store.payload = {
      appointments: [
        {
          id: 3,
          resourceId: 5,
          startsAt: '2026-03-11T08:00:00.000Z',
          endsAt: '2026-03-11T08:30:00.000Z',
          status: 'confirmed',
        },
      ],
      breakRules: [],
      expenses: [],
      holidays: [],
      payments: [],
      range: { from: null, to: null },
      resources: [],
      slots: [],
      timeOffs: [],
      workRules: [],
      workdayOverrides: [],
    };

    store.syncAppointment({
      id: 3,
      resource_id: 9,
      starts_at: '2026-03-11T08:00:00.000Z',
      ends_at: '2026-03-11T08:30:00.000Z',
      status: 'cancelled',
    });

    expect(store.payload.appointments).toEqual([]);
  });

  it('keeps synced appointments when they stay inside the active view and filters', () => {
    const store = useSchedulingCalendarStore();
    store.currentView = 'week';
    store.anchorDate = '2026-03-09T00:00:00.000Z';
    store.selectedResourceIds = [5];
    store.statusFilters = ['confirmed'];

    store.syncAppointment({
      id: 7,
      resource_id: 5,
      starts_at: '2026-03-11T09:00:00.000Z',
      ends_at: '2026-03-11T09:30:00.000Z',
      status: 'confirmed',
    });

    expect(store.payload.appointments).toEqual([
      {
        id: 7,
        resourceId: 5,
        startsAt: '2026-03-11T09:00:00.000Z',
        endsAt: '2026-03-11T09:30:00.000Z',
        status: 'confirmed',
      },
    ]);
  });

  it('removes synced appointments that no longer match active custom field filters', () => {
    const store = useSchedulingCalendarStore();
    const crmReferencesStore = useCrmReferencesStore();
    crmReferencesStore.fieldDefinitions.appointment = [
      {
        fieldType: 'select',
        key: 'visit_reason',
      },
    ];

    store.currentView = 'week';
    store.anchorDate = '2026-03-09T00:00:00.000Z';
    store.setCustomAttributeFilters({
      visit_reason: ['follow_up'],
    });
    store.payload = {
      appointments: [
        {
          customAttributes: { visit_reason: 'follow_up' },
          endsAt: '2026-03-11T08:30:00.000Z',
          id: 3,
          resourceId: 5,
          startsAt: '2026-03-11T08:00:00.000Z',
          status: 'confirmed',
        },
      ],
      breakRules: [],
      expenses: [],
      holidays: [],
      payments: [],
      range: { from: null, to: null },
      resources: [],
      slots: [],
      timeOffs: [],
      workRules: [],
      workdayOverrides: [],
    };

    store.syncAppointment({
      custom_attributes: { visit_reason: 'initial' },
      ends_at: '2026-03-11T08:30:00.000Z',
      id: 3,
      resource_id: 5,
      starts_at: '2026-03-11T08:00:00.000Z',
      status: 'confirmed',
    });

    expect(store.payload.appointments).toEqual([]);
  });

  it('keeps synced appointments that still match active custom field filters', () => {
    const store = useSchedulingCalendarStore();
    const crmReferencesStore = useCrmReferencesStore();
    crmReferencesStore.fieldDefinitions.appointment = [
      {
        fieldType: 'select',
        key: 'visit_reason',
      },
    ];

    store.currentView = 'week';
    store.anchorDate = '2026-03-09T00:00:00.000Z';
    store.setCustomAttributeFilters({
      visit_reason: ['follow_up'],
    });

    store.syncAppointment({
      custom_attributes: { visit_reason: 'follow_up' },
      ends_at: '2026-03-11T09:30:00.000Z',
      id: 7,
      resource_id: 5,
      starts_at: '2026-03-11T09:00:00.000Z',
      status: 'confirmed',
    });

    expect(store.payload.appointments).toEqual([
      {
        customAttributes: { visit_reason: 'follow_up' },
        endsAt: '2026-03-11T09:30:00.000Z',
        id: 7,
        resourceId: 5,
        startsAt: '2026-03-11T09:00:00.000Z',
        status: 'confirmed',
      },
    ]);
  });

  it('ignores stale calendar responses that finish after a newer filtered request', async () => {
    const store = useSchedulingCalendarStore();
    let resolveFirstRequest;
    let resolveSecondRequest;

    showMock
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveFirstRequest = resolve;
          })
      )
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveSecondRequest = resolve;
          })
      );

    store.selectedResourceIds = [5];
    const firstRequest = store.fetchCalendar();

    store.selectedResourceIds = [8];
    const secondRequest = store.fetchCalendar();

    resolveSecondRequest({
      data: {
        payload: {
          appointments: [
            {
              id: 8,
              resource_id: 8,
              starts_at: '2026-03-11T09:00:00.000Z',
              ends_at: '2026-03-11T09:30:00.000Z',
            },
          ],
          break_rules: [],
          expenses: [],
          holidays: [],
          payments: [],
          range: {
            from: '2026-03-09T00:00:00.000Z',
            to: '2026-03-16T00:00:00.000Z',
          },
          resources: [{ id: 8, name: 'Dr. Eight' }],
          slots: [],
          time_offs: [],
          work_rules: [],
          workday_overrides: [],
        },
      },
    });

    await secondRequest;

    resolveFirstRequest({
      data: {
        payload: {
          appointments: [
            {
              id: 5,
              resource_id: 5,
              starts_at: '2026-03-11T08:00:00.000Z',
              ends_at: '2026-03-11T08:30:00.000Z',
            },
          ],
          break_rules: [],
          expenses: [],
          holidays: [],
          payments: [],
          range: {
            from: '2026-03-09T00:00:00.000Z',
            to: '2026-03-16T00:00:00.000Z',
          },
          resources: [{ id: 5, name: 'Dr. Five' }],
          slots: [],
          time_offs: [],
          work_rules: [],
          workday_overrides: [],
        },
      },
    });

    await firstRequest;

    expect(store.payload.resources).toEqual([{ id: 8, name: 'Dr. Eight' }]);
    expect(store.payload.appointments).toEqual([
      {
        endsAt: '2026-03-11T09:30:00.000Z',
        id: 8,
        resourceId: 8,
        startsAt: '2026-03-11T09:00:00.000Z',
      },
    ]);
  });
});
