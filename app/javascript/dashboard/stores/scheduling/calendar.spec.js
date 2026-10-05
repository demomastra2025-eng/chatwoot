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
    expect(store.visibleResources).toEqual([{ id: 5, name: 'Dr. Sam' }]);
  });

  it('requests Workspace-timezone day boundaries once a timezone is set', async () => {
    showMock.mockResolvedValue({ data: { payload: {} } });
    const store = useSchedulingCalendarStore();
    store.setView('day');
    // 20:30 UTC on 8 March is already 9 March in Almaty (UTC+5).
    store.setAnchorDate('2026-03-08T20:30:00.000Z');
    store.setWorkspaceTimezone('Asia/Almaty');

    await store.fetchCalendar();

    expect(showMock).toHaveBeenCalledWith(
      expect.objectContaining({
        from: '2026-03-08T19:00:00.000Z',
        to: '2026-03-09T18:59:59.999Z',
        view: 'day',
      })
    );
    expect(store.currentRange.from.toISOString()).toBe(
      '2026-03-08T19:00:00.000Z'
    );
  });

  it('keeps browser-local day boundaries without a Workspace timezone', async () => {
    showMock.mockResolvedValue({ data: { payload: {} } });
    const store = useSchedulingCalendarStore();
    store.setView('day');
    store.setAnchorDate('2026-03-08T20:30:00.000Z');

    await store.fetchCalendar();

    // The browser-local day of the anchor, in any process timezone.
    const anchor = new Date('2026-03-08T20:30:00.000Z');
    const localDay = [
      anchor.getFullYear(),
      anchor.getMonth(),
      anchor.getDate(),
    ];
    expect(showMock).toHaveBeenCalledWith(
      expect.objectContaining({
        from: new Date(...localDay).toISOString(),
        to: new Date(...localDay, 23, 59, 59, 999).toISOString(),
      })
    );
  });

  it('shifts the anchor across Workspace calendar days', () => {
    const store = useSchedulingCalendarStore();
    store.setView('day');
    store.setAnchorDate('2026-03-08T20:30:00.000Z');
    store.setWorkspaceTimezone('Asia/Almaty');

    store.shiftAnchor(1);

    expect(store.anchorDate).toBe('2026-03-09T20:30:00.000Z');
    expect(store.currentRange.from.toISOString()).toBe(
      '2026-03-09T19:00:00.000Z'
    );
  });

  it('keeps realtime appointments that fall inside the Workspace day', () => {
    const store = useSchedulingCalendarStore();
    store.currentView = 'day';
    store.anchorDate = '2026-03-09T06:00:00.000Z';
    store.setWorkspaceTimezone('Asia/Almaty');

    // 19:30 UTC on 8 March is 00:30 on 9 March in Almaty.
    store.syncAppointment({
      ends_at: '2026-03-08T20:00:00.000Z',
      id: 11,
      resource_id: 5,
      starts_at: '2026-03-08T19:30:00.000Z',
      status: 'confirmed',
    });

    expect(store.payload.appointments.map(item => item.id)).toEqual([11]);
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
