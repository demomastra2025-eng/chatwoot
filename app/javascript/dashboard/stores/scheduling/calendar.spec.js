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
          appointments: [{ id: 3, service_amount: 5000 }],
          break_rules: [],
          holidays: [],
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

    const payload = await store.fetchCalendar();

    expect(store.currentView).toBe('day');
    expect(store.anchorDate).toBe('2026-03-09T00:00:00.000Z');
    expect(store.selectedResourceIds).toEqual([5, 8]);
    expect(showMock).toHaveBeenCalledWith(
      expect.objectContaining({
        include_slots: true,
        resource_ids: '5,8',
        status: 'confirmed',
        view: 'day',
      })
    );
    expect(payload.resources).toEqual([{ id: 5, name: 'Dr. Sam' }]);
    expect(payload.appointments).toEqual([{ id: 3, serviceAmount: 5000 }]);
    expect(payload).not.toHaveProperty('payments');
    expect(payload).not.toHaveProperty('expenses');
    expect(store.visibleResources).toEqual([{ id: 5, name: 'Dr. Sam' }]);
  });

  it('ignores a pending calendar response after request invalidation', async () => {
    let resolveRequest;
    showMock.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );
    const store = useSchedulingCalendarStore();
    const request = store.fetchCalendar({ paginateAppointments: true });

    store.invalidateRequests();
    resolveRequest({
      data: {
        meta: { count: 1, page: 1, per_page: 25 },
        payload: { appointments: [{ id: 99 }] },
      },
    });
    await request;

    expect(store.appointments).toEqual([]);
    expect(store.listTotal).toBe(0);
    expect(store.ui.isLoading).toBe(false);
  });

  it('clears account-scoped calendar state before loading another account', () => {
    const store = useSchedulingCalendarStore();
    store.payload = {
      ...store.payload,
      appointments: [{ id: 99 }],
      resources: [{ id: 5 }],
    };
    store.customAttributeFilters = {
      urgency: { operator: 'equal', value: 'high' },
    };
    store.listPage = 3;
    store.listTotal = 51;
    store.selectedResourceIds = [5];
    store.statusFilters = ['confirmed'];
    store.ui.error = { message: 'Old account error' };
    store.ui.lastLoadedAt = '2026-09-19T00:00:00Z';

    store.resetForAccountChange();

    expect(store.appointments).toEqual([]);
    expect(store.resources).toEqual([]);
    expect(store.customAttributeFilters).toEqual({});
    expect(store.listPage).toBe(1);
    expect(store.listTotal).toBe(0);
    expect(store.selectedResourceIds).toEqual([]);
    expect(store.statusFilters).toEqual([]);
    expect(store.ui).toEqual({
      error: null,
      isLoading: true,
      lastLoadedAt: null,
    });
  });

  it('passes appointment custom field filters to the calendar request', async () => {
    showMock.mockResolvedValue({
      data: {
        payload: {
          appointments: [],
          break_rules: [],
          holidays: [],
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

  it('requests one bounded appointment list page and stores the server count', async () => {
    showMock.mockResolvedValue({
      data: {
        meta: { count: 51, page: 2, per_page: 25 },
        payload: {
          appointments: [{ id: 26 }],
        },
      },
    });
    const store = useSchedulingCalendarStore();
    store.setListPage(2);

    await store.fetchCalendar({ paginateAppointments: true });

    expect(showMock).toHaveBeenCalledWith(
      expect.objectContaining({
        page: 2,
        paginate_appointments: true,
        per_page: 25,
      })
    );
    expect(store.listTotal).toBe(51);
    expect(store.listTotalPages).toBe(3);
    expect(store.appointments).toEqual([{ id: 26 }]);
  });

  it('keeps an old API full-list payload usable when pagination metadata is absent', async () => {
    const appointments = Array.from({ length: 30 }, (_, index) => ({
      id: index + 1,
    }));
    showMock.mockResolvedValue({
      data: {
        payload: { appointments },
      },
    });
    const store = useSchedulingCalendarStore();

    await store.fetchCalendar({ paginateAppointments: true });

    expect(store.appointments).toEqual(appointments);
    expect(store.listTotal).toBe(0);
    expect(store.listTotalPages).toBe(1);
  });

  it('reloads the last valid appointment list page after the current page becomes empty', async () => {
    showMock
      .mockResolvedValueOnce({
        data: {
          meta: { count: 26, page: 3, per_page: 25 },
          payload: { appointments: [] },
        },
      })
      .mockResolvedValueOnce({
        data: {
          meta: { count: 26, page: 2, per_page: 25 },
          payload: { appointments: [{ id: 26 }] },
        },
      });
    const store = useSchedulingCalendarStore();
    store.setListPage(3);

    await store.fetchCalendar({ paginateAppointments: true });

    expect(showMock.mock.calls.map(([params]) => params.page)).toEqual([3, 2]);
    expect(store.listPage).toBe(2);
    expect(store.appointments).toEqual([{ id: 26 }]);
  });

  it('hides inactive appointments by default and includes them on opt-in', async () => {
    showMock.mockResolvedValue({ data: { payload: {} } });
    const store = useSchedulingCalendarStore();

    await store.fetchCalendar();

    expect(showMock).toHaveBeenLastCalledWith(
      expect.objectContaining({ status: 'scheduled,confirmed' })
    );

    store.setShowInactiveAppointments(true);
    await store.fetchCalendar();

    expect(showMock.mock.calls.at(-1)[0]).not.toHaveProperty('status');
    expect(
      JSON.parse(window.localStorage.getItem(CALENDAR_STORAGE_KEY))
        .showInactiveAppointments
    ).toBe(true);
  });

  it('resets all appointment filters without changing calendar navigation', () => {
    const store = useSchedulingCalendarStore();
    store.setStatusFilters(['confirmed']);
    store.setCustomAttributeFilters({ visit_reason: ['follow_up'] });
    store.setShowInactiveAppointments(true);
    store.setView('month');

    store.resetFilters();

    expect(store.statusFilters).toEqual([]);
    expect(store.customAttributeFilters).toEqual({});
    expect(store.showInactiveAppointments).toBe(false);
    expect(store.currentView).toBe('month');
  });

  it('does not expose all specialists when no resource is selected', () => {
    const store = useSchedulingCalendarStore();

    store.payload = {
      appointments: [],
      breakRules: [],
      holidays: [],
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

  it('merges an updated appointment without exposing historical finance payloads', () => {
    const store = useSchedulingCalendarStore();

    store.payload = {
      appointments: [
        {
          id: 3,
          startsAt: '2026-03-11T08:00:00.000Z',
        },
      ],
      breakRules: [],
      holidays: [],
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
        id: 3,
        startsAt: '2026-03-11T08:30:00.000Z',
      },
    ]);
    expect(store.payload).not.toHaveProperty('payments');
    expect(store.payload.appointments[0]).not.toHaveProperty('expense');
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
      holidays: [],
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

  it('applies inactive visibility to realtime appointment updates', () => {
    const store = useSchedulingCalendarStore();
    store.currentView = 'week';
    store.anchorDate = '2026-03-09T00:00:00.000Z';
    const completedAppointment = {
      ends_at: '2026-03-11T09:30:00.000Z',
      id: 7,
      resource_id: 5,
      starts_at: '2026-03-11T09:00:00.000Z',
      status: 'completed',
    };

    store.syncAppointment(completedAppointment);
    expect(store.payload.appointments).toEqual([]);

    store.setShowInactiveAppointments(true);
    store.syncAppointment(completedAppointment);

    expect(store.payload.appointments).toHaveLength(1);
    expect(store.payload.appointments[0].status).toBe('completed');
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
      holidays: [],
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
          holidays: [],
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
          holidays: [],
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
