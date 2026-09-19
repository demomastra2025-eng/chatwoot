import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useSchedulingReferencesStore } from './references';

const {
  currentAccount,
  createServiceMock,
  createResourceMock,
  createHolidayMock,
  deleteServiceMock,
  getBreakRulesMock,
  getHolidaysMock,
  getResourcesMock,
  getScheduleMock,
  getServicesMock,
  getTimeOffsMock,
  getWorkRulesMock,
  getWorkdayOverridesMock,
  updateBreakRulesMock,
  updateHolidayMock,
  updateResourceMock,
  updateScheduleMock,
  updateServiceMock,
  updateTimeOffMock,
  updateWorkRulesMock,
  updateWorkdayOverrideMock,
  deleteResourceMock,
  deleteHolidayMock,
  deleteTimeOffMock,
  deleteWorkdayOverrideMock,
} = vi.hoisted(() => ({
  currentAccount: { id: '1' },
  createHolidayMock: vi.fn(),
  createResourceMock: vi.fn(),
  createServiceMock: vi.fn(),
  deleteHolidayMock: vi.fn(),
  deleteResourceMock: vi.fn(),
  deleteServiceMock: vi.fn(),
  deleteTimeOffMock: vi.fn(),
  deleteWorkdayOverrideMock: vi.fn(),
  getBreakRulesMock: vi.fn(),
  getHolidaysMock: vi.fn(),
  getResourcesMock: vi.fn(),
  getScheduleMock: vi.fn(),
  getServicesMock: vi.fn(),
  getTimeOffsMock: vi.fn(),
  getWorkRulesMock: vi.fn(),
  getWorkdayOverridesMock: vi.fn(),
  updateBreakRulesMock: vi.fn(),
  updateHolidayMock: vi.fn(),
  updateResourceMock: vi.fn(),
  updateScheduleMock: vi.fn(),
  updateServiceMock: vi.fn(),
  updateTimeOffMock: vi.fn(),
  updateWorkRulesMock: vi.fn(),
  updateWorkdayOverrideMock: vi.fn(),
}));

vi.mock('dashboard/api/scheduling/resources', () => ({
  default: {
    get accountIdFromRoute() {
      return currentAccount.id;
    },
    create: createResourceMock,
    delete: deleteResourceMock,
    get: getResourcesMock,
    getBreakRules: getBreakRulesMock,
    getSchedule: getScheduleMock,
    getWorkRules: getWorkRulesMock,
    update: updateResourceMock,
    updateSchedule: updateScheduleMock,
    updateBreakRules: updateBreakRulesMock,
    updateWorkRules: updateWorkRulesMock,
  },
}));

vi.mock('dashboard/api/scheduling/services', () => ({
  default: {
    get accountIdFromRoute() {
      return currentAccount.id;
    },
    create: createServiceMock,
    delete: deleteServiceMock,
    get: getServicesMock,
    update: updateServiceMock,
  },
}));

vi.mock('dashboard/api/scheduling/exceptions', () => ({
  default: {
    createHoliday: createHolidayMock,
    createTimeOff: vi.fn(),
    createWorkdayOverride: vi.fn(),
    deleteHoliday: deleteHolidayMock,
    deleteTimeOff: deleteTimeOffMock,
    deleteWorkdayOverride: deleteWorkdayOverrideMock,
    getHolidays: getHolidaysMock,
    getTimeOffs: getTimeOffsMock,
    getWorkdayOverrides: getWorkdayOverridesMock,
    updateHoliday: updateHolidayMock,
    updateTimeOff: updateTimeOffMock,
    updateWorkdayOverride: updateWorkdayOverrideMock,
  },
}));

describe('useSchedulingReferencesStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
    currentAccount.id = '1';
  });

  it('does not publish stale resources and services after an account reset', async () => {
    const store = useSchedulingReferencesStore();
    let resolveOldResources;
    let resolveOldServices;
    getResourcesMock
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveOldResources = resolve;
          })
      )
      .mockResolvedValueOnce({
        data: { payload: [{ id: 2, name: 'B resource' }] },
      });
    getServicesMock
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveOldServices = resolve;
          })
      )
      .mockResolvedValueOnce({
        data: { payload: [{ id: 2, name: 'B service' }] },
      });

    const oldLoads = Promise.all([store.loadResources(), store.loadServices()]);
    currentAccount.id = '2';
    store.resetForAccountChange();
    await Promise.all([store.loadResources(), store.loadServices()]);
    resolveOldResources({ data: { payload: [{ id: 1, name: 'A resource' }] } });
    resolveOldServices({ data: { payload: [{ id: 1, name: 'A service' }] } });
    await oldLoads;

    expect(store.resources).toEqual([{ id: 2, name: 'B resource' }]);
    expect(store.services).toEqual([{ id: 2, name: 'B service' }]);
    expect(store.ui.error).toBe(null);
  });

  it('clears stale errors when saving a resource succeeds', async () => {
    const store = useSchedulingReferencesStore();
    store.ui.error = { code: 'RESOURCE_HAS_APPOINTMENTS', message: 'stale' };

    createResourceMock.mockResolvedValue({
      data: {
        payload: {
          active: true,
          id: 12,
          name: 'Dr. Sam',
        },
      },
    });

    const resource = await store.saveResource({ name: 'Dr. Sam' });

    expect(createResourceMock).toHaveBeenCalledWith({ name: 'Dr. Sam' });
    expect(resource).toMatchObject({ id: 12, name: 'Dr. Sam' });
    expect(store.resources).toMatchObject([{ id: 12, name: 'Dr. Sam' }]);
    expect(store.ui.error).toBe(null);
  });

  it('uses the atomic schedule endpoint when the API capability is present', async () => {
    const store = useSchedulingReferencesStore();
    store.resources = [{ id: 12, scheduleUpdateSupported: true }];
    const schedule = {
      inherit_working_hours_from_account: false,
      work_rules: [],
      break_rules: [],
    };
    updateScheduleMock.mockResolvedValue({
      data: {
        payload: {
          resource: { id: 12, schedule_update_supported: true },
          work_rules: [],
          break_rules: [],
        },
      },
    });

    const savedSchedule = await store.saveResourceSchedule(12, schedule);

    expect(updateScheduleMock).toHaveBeenCalledWith(12, schedule);
    expect(updateWorkRulesMock).not.toHaveBeenCalled();
    expect(savedSchedule.resource.id).toBe(12);
    expect(store.resources).toEqual([
      { id: 12, scheduleUpdateSupported: true },
    ]);
    expect(store.ui.isSaving).toBe(false);
  });

  it('loads an atomic schedule and its revision when the capability is present', async () => {
    const store = useSchedulingReferencesStore();
    store.resources = [{ id: 12, scheduleUpdateSupported: true }];
    getScheduleMock.mockResolvedValue({
      data: {
        payload: {
          resource: { id: 12, schedule_update_supported: true },
          schedule_revision: 'revision-1',
          work_rules: [{ weekday: 1 }],
          break_rules: [{ weekday: 1 }],
        },
      },
    });

    const schedule = await store.loadResourceSchedule(12);

    expect(getScheduleMock).toHaveBeenCalledWith(12);
    expect(schedule.scheduleRevision).toBe('revision-1');
    expect(store.workRulesByResource).toEqual({});
    expect(store.breakRulesByResource).toEqual({});

    store.commitResourceSchedule(12, schedule);

    expect(store.workRulesByResource[12]).toEqual([{ weekday: 1 }]);
    expect(store.breakRulesByResource[12]).toEqual([{ weekday: 1 }]);
  });

  it('falls back to legacy schedule endpoints when the capability is absent', async () => {
    const store = useSchedulingReferencesStore();
    store.resources = [{ id: 12 }];
    const schedule = {
      inherit_working_hours_from_account: false,
      work_rules: [{ weekday: 1 }],
      break_rules: [{ weekday: 1 }],
    };
    updateWorkRulesMock.mockResolvedValue({
      data: { payload: schedule.work_rules },
    });
    updateBreakRulesMock.mockResolvedValue({
      data: { payload: schedule.break_rules },
    });

    await store.saveResourceSchedule(12, schedule);

    expect(updateScheduleMock).not.toHaveBeenCalled();
    expect(updateWorkRulesMock).toHaveBeenCalledWith(12, schedule.work_rules);
    expect(updateBreakRulesMock).toHaveBeenCalledWith(12, schedule.break_rules);
  });

  it('removes a deleted service from the local store state', async () => {
    const store = useSchedulingReferencesStore();
    store.services = [
      { id: 10, name: 'Consultation' },
      { id: 20, name: 'Diagnostics' },
    ];
    store.ui.error = { code: 'GENERIC', message: 'stale' };

    deleteServiceMock.mockResolvedValue({});

    await store.deleteService(10);

    expect(deleteServiceMock).toHaveBeenCalledWith(10);
    expect(store.services).toEqual([{ id: 20, name: 'Diagnostics' }]);
    expect(store.ui.error).toBe(null);
  });

  it('keeps a failed resource delete out of page-level load errors', async () => {
    const store = useSchedulingReferencesStore();
    store.resources = [{ id: 72, name: 'Dr. Sam', active: true }];

    const error = {
      response: {
        status: 422,
        data: {
          code: 'RESOURCE_HAS_APPOINTMENTS',
          error:
            'Specialist with current or future active appointments cannot be deleted',
          details: {
            blocking_appointment_count: 1,
            blocking_appointments: [{ id: 4570 }],
          },
        },
      },
    };
    deleteResourceMock.mockRejectedValue(error);

    await expect(store.deleteResource(72)).rejects.toBe(error);

    expect(deleteResourceMock).toHaveBeenCalledWith(72);
    expect(store.resources).toEqual([
      { id: 72, name: 'Dr. Sam', active: true },
    ]);
    expect(store.ui.error).toBe(null);
  });

  it('removes a deleted holiday from the local store state', async () => {
    const store = useSchedulingReferencesStore();
    store.holidays = [
      { id: 1, title: 'Nauryz' },
      { id: 2, title: 'New Year' },
    ];
    store.ui.error = { code: 'GENERIC', message: 'stale' };

    deleteHolidayMock.mockResolvedValue({});

    await store.deleteHoliday(1);

    expect(deleteHolidayMock).toHaveBeenCalledWith(1);
    expect(store.holidays).toEqual([{ id: 2, title: 'New Year' }]);
    expect(store.ui.error).toBe(null);
  });
});
