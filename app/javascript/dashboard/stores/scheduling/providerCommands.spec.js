import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';
import { useSchedulingProviderCommandsStore } from './providerCommands';

vi.mock('dashboard/api/scheduling/providerCommands', () => ({
  default: {
    confirm: vi.fn(),
    create: vi.fn(),
    get: vi.fn(),
  },
}));

describe('useSchedulingProviderCommandsStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

  it('creates, confirms, and polls a command until it succeeds', async () => {
    SchedulingProviderCommandsAPI.create.mockResolvedValue({
      data: { payload: { id: 41, status: 'awaiting_confirmation' } },
    });
    SchedulingProviderCommandsAPI.confirm.mockResolvedValue({
      data: { payload: { id: 41, status: 'queued' } },
    });
    SchedulingProviderCommandsAPI.get.mockResolvedValue({
      data: { payload: { id: 41, status: 'succeeded' } },
    });
    const store = useSchedulingProviderCommandsStore();

    const command = await store.executeConfirmed(
      {
        appointment_id: 17,
        operation: 'remove_reception',
      },
      { pollIntervalMs: 0 }
    );

    expect(SchedulingProviderCommandsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        appointment_id: 17,
        idempotency_key: expect.stringContaining(
          'scheduling-dashboard:remove_reception:17:'
        ),
        operation: 'remove_reception',
      })
    );
    expect(SchedulingProviderCommandsAPI.confirm).toHaveBeenCalledWith(41);
    expect(SchedulingProviderCommandsAPI.get).toHaveBeenCalledWith(41);
    expect(command.status).toBe('succeeded');
    expect(store.lastCommand.status).toBe('succeeded');
    expect(store.ui.isExecuting).toBe(false);
  });

  it('returns a queued command when polling reaches its limit', async () => {
    SchedulingProviderCommandsAPI.create.mockResolvedValue({
      data: { payload: { id: 42, status: 'awaiting_confirmation' } },
    });
    SchedulingProviderCommandsAPI.confirm.mockResolvedValue({
      data: { payload: { id: 42, status: 'queued' } },
    });
    const store = useSchedulingProviderCommandsStore();

    const command = await store.executeConfirmed(
      {
        appointment_id: 18,
        operation: 'create_reception',
      },
      { maxPollAttempts: 0, pollIntervalMs: 0 }
    );

    expect(command.status).toBe('queued');
    expect(SchedulingProviderCommandsAPI.get).not.toHaveBeenCalled();
  });

  it('continues polling while automatic reconciliation is pending', async () => {
    SchedulingProviderCommandsAPI.create.mockResolvedValue({
      data: { payload: { id: 43, status: 'awaiting_confirmation' } },
    });
    SchedulingProviderCommandsAPI.confirm.mockResolvedValue({
      data: { payload: { id: 43, status: 'queued' } },
    });
    SchedulingProviderCommandsAPI.get
      .mockResolvedValueOnce({
        data: { payload: { id: 43, status: 'reconciliation_required' } },
      })
      .mockResolvedValueOnce({
        data: { payload: { id: 43, status: 'succeeded' } },
      });
    const store = useSchedulingProviderCommandsStore();

    const command = await store.executeConfirmed(
      {
        appointment_id: 19,
        operation: 'move_reception',
      },
      { pollIntervalMs: 0 }
    );

    expect(SchedulingProviderCommandsAPI.get).toHaveBeenCalledTimes(2);
    expect(command.status).toBe('succeeded');
    expect(store.lastCommand.status).toBe('succeeded');
  });
});
