import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';
import {
  buildProviderCommandAction,
  buildProviderCommandParamsFromCommand,
  providerCommandIntentMatches,
  useSchedulingProviderCommandsStore,
} from './providerCommands';

vi.mock('dashboard/api/scheduling/providerCommands', () => ({
  default: {
    cancel: vi.fn(),
    confirm: vi.fn(),
    confirmPatientCreation: vi.fn(),
    create: vi.fn(),
    get: vi.fn(),
    list: vi.fn(),
    patientCandidates: vi.fn(),
    retry: vi.fn(),
    selectPatient: vi.fn(),
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
    expect(SchedulingProviderCommandsAPI.confirm).toHaveBeenCalledWith(41, {
      automatic: true,
    });
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

  it('resumes a provider-scoped patient selection and polls it to success', async () => {
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          {
            id: 44,
            provider: 'medelement',
            status: 'awaiting_patient_selection',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
      data: { payload: { candidates: [{ token: 'candidate-token' }] } },
    });
    SchedulingProviderCommandsAPI.selectPatient.mockResolvedValue({
      data: {
        payload: { id: 44, provider: 'medelement', status: 'queued' },
      },
    });
    SchedulingProviderCommandsAPI.get.mockResolvedValue({
      data: {
        payload: { id: 44, provider: 'medelement', status: 'succeeded' },
      },
    });
    const store = useSchedulingProviderCommandsStore();

    const activeCommand = await store.findActive({
      appointmentId: 20,
      provider: 'medelement',
    });
    const candidates = await store.loadPatientCandidates(activeCommand);
    const command = await store.selectPatient(
      activeCommand,
      candidates.candidates[0].token
    );

    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledWith({
      activeOnly: true,
      appointmentId: 20,
      provider: 'medelement',
    });
    expect(
      SchedulingProviderCommandsAPI.patientCandidates
    ).toHaveBeenCalledWith(44, { provider: 'medelement' });
    expect(SchedulingProviderCommandsAPI.selectPatient).toHaveBeenCalledWith(
      44,
      {
        provider: 'medelement',
        token: 'candidate-token',
      }
    );
    expect(SchedulingProviderCommandsAPI.get).toHaveBeenCalledWith(44, {
      provider: 'medelement',
    });
    expect(command.status).toBe('succeeded');
  });

  it('retries a provider-scoped phone mismatch command without creating a duplicate', async () => {
    const activeCommand = {
      appointmentId: 20,
      id: 45,
      operation: 'create_reception',
      provider: 'medelement',
      status: 'awaiting_phone_refresh',
    };
    SchedulingProviderCommandsAPI.retry.mockResolvedValue({
      data: { payload: { ...activeCommand, status: 'queued' } },
    });
    SchedulingProviderCommandsAPI.get.mockResolvedValue({
      data: { payload: { ...activeCommand, status: 'succeeded' } },
    });
    const store = useSchedulingProviderCommandsStore();

    const command = await store.retryPhoneMismatch(activeCommand);

    expect(SchedulingProviderCommandsAPI.retry).toHaveBeenCalledWith(45, {
      provider: 'medelement',
    });
    expect(SchedulingProviderCommandsAPI.create).not.toHaveBeenCalled();
    expect(command.status).toBe('succeeded');
  });

  it('reconstructs the immutable command intent and rejects a different confirmation action', async () => {
    const activeCommand = {
      appointmentId: 21,
      companyCabinetCode: 'CAB-A',
      desiredEndsAt: '2026-03-09T11:30:00.000Z',
      desiredStartsAt: '2026-03-09T11:00:00.000Z',
      id: 45,
      operation: 'move_reception',
      provider: 'medelement',
      status: 'awaiting_confirmation',
    };
    const requestedIntent = {
      appointment_id: 21,
      company_cabinet_code: 'CAB-B',
      desired_ends_at: '2026-03-09T12:30:00.000Z',
      desired_starts_at: '2026-03-09T12:00:00.000Z',
      operation: 'move_reception',
      provider: 'medelement',
    };
    const store = useSchedulingProviderCommandsStore();
    const stagedAction = buildProviderCommandAction(
      { appointment: { id: 21 }, params: requestedIntent },
      activeCommand
    );

    expect(stagedAction).toMatchObject({
      command: activeCommand,
      intentMismatch: true,
      params: {
        appointment_id: 21,
        company_cabinet_code: 'CAB-A',
        desired_ends_at: '2026-03-09T11:30:00.000Z',
        desired_starts_at: '2026-03-09T11:00:00.000Z',
        operation: 'move_reception',
        provider: 'medelement',
      },
      requestedParams: requestedIntent,
    });
    expect(buildProviderCommandParamsFromCommand(activeCommand)).toEqual({
      appointment_id: 21,
      company_cabinet_code: 'CAB-A',
      desired_ends_at: '2026-03-09T11:30:00.000Z',
      desired_starts_at: '2026-03-09T11:00:00.000Z',
      operation: 'move_reception',
      provider: 'medelement',
    });
    expect(providerCommandIntentMatches(requestedIntent, activeCommand)).toBe(
      false
    );
    await expect(
      store.confirmExisting(activeCommand, requestedIntent)
    ).rejects.toMatchObject({ code: 'provider_command_intent_mismatch' });
    expect(SchedulingProviderCommandsAPI.confirm).not.toHaveBeenCalled();
    expect(store.ui.isExecuting).toBe(false);
  });

  it('matches equivalent immutable move timestamps with different ISO offsets', () => {
    const command = {
      appointmentId: 22,
      companyCabinetCode: 'CAB-A',
      desiredEndsAt: '2026-03-09T11:30:00.000Z',
      desiredStartsAt: '2026-03-09T11:00:00.000Z',
      operation: 'move_reception',
      provider: 'medelement',
    };

    expect(
      providerCommandIntentMatches(
        {
          appointment_id: 22,
          company_cabinet_code: 'CAB-A',
          desired_ends_at: '2026-03-09T17:30:00+06:00',
          desired_starts_at: '2026-03-09T17:00:00+06:00',
          operation: 'move_reception',
          provider: 'medelement',
        },
        command
      )
    ).toBe(true);
  });
});
