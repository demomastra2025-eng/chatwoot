import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useSchedulingReferencesStore } from './references';

const {
  createServiceMock,
  createResourceMock,
  createHolidayMock,
  deleteServiceMock,
  getBreakRulesMock,
  getHolidaysMock,
  getResourcesMock,
  getServicesMock,
  getTimeOffsMock,
  getWorkRulesMock,
  getWorkdayOverridesMock,
  updateBreakRulesMock,
  updateHolidayMock,
  updateResourceMock,
  updateServiceMock,
  updateTimeOffMock,
  updateWorkRulesMock,
  updateWorkdayOverrideMock,
  deleteResourceMock,
  deleteHolidayMock,
  deleteTimeOffMock,
  deleteWorkdayOverrideMock,
} = vi.hoisted(() => ({
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
  getServicesMock: vi.fn(),
  getTimeOffsMock: vi.fn(),
  getWorkRulesMock: vi.fn(),
  getWorkdayOverridesMock: vi.fn(),
  updateBreakRulesMock: vi.fn(),
  updateHolidayMock: vi.fn(),
  updateResourceMock: vi.fn(),
  updateServiceMock: vi.fn(),
  updateTimeOffMock: vi.fn(),
  updateWorkRulesMock: vi.fn(),
  updateWorkdayOverrideMock: vi.fn(),
}));

vi.mock('dashboard/api/scheduling/resources', () => ({
  default: {
    create: createResourceMock,
    delete: deleteResourceMock,
    get: getResourcesMock,
    getBreakRules: getBreakRulesMock,
    getWorkRules: getWorkRulesMock,
    update: updateResourceMock,
    updateBreakRules: updateBreakRulesMock,
    updateWorkRules: updateWorkRulesMock,
  },
}));

vi.mock('dashboard/api/scheduling/services', () => ({
  default: {
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
