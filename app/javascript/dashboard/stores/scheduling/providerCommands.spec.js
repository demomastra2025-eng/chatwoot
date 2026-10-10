import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';
import { runCurrentCalendarProviderAction } from './appointmentForm';
import {
  buildProviderCommandAction,
  buildProviderCommandParamsFromCommand,
  providerCommandIntentMatches,
  providerCommandRequiresPatientSelection,
  useSchedulingProviderCommandsStore,
} from './providerCommands';

describe('server-authorized failed patient selection', () => {
  it('requires explicit confirmation metadata and keeps ordinary failures terminal', () => {
    const command = {
      status: 'failed',
      patientAction: {
        type: 'patient_selection',
        canConfirm: true,
        requiresPatientCardConfirmation: true,
      },
    };
    expect(providerCommandRequiresPatientSelection(command)).toBe(true);
    expect(providerCommandRequiresPatientSelection({ status: 'failed' })).toBe(
      false
    );
    expect(
      providerCommandRequiresPatientSelection({
        ...command,
        patientAction: { ...command.patientAction, canConfirm: false },
      })
    ).toBe(false);
    expect(
      providerCommandRequiresPatientSelection({
        ...command,
        patientAction: {
          ...command.patientAction,
          requiresPatientCardConfirmation: false,
        },
      })
    ).toBe(false);
  });
});

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

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};
const patientCommand = {
  id: 91,
  appointmentId: 20,
  operation: 'create_reception',
  provider: 'medelement',
  companyCabinetCode: 'CAB-20',
  status: 'awaiting_patient_selection',
};

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

  it('does not publish a resumed command after its owning context is stale', async () => {
    let resolveSelection;
    SchedulingProviderCommandsAPI.selectPatient.mockReturnValue(
      new Promise(resolve => {
        resolveSelection = resolve;
      })
    );
    const activeCommand = {
      appointmentId: 20,
      companyCabinetCode: 'CAB-20',
      id: 46,
      operation: 'create_reception',
      provider: 'medelement',
      status: 'awaiting_patient_selection',
    };
    const store = useSchedulingProviderCommandsStore();
    let isCurrent = true;
    const continuation = store.selectPatient(
      activeCommand,
      'candidate-token',
      buildProviderCommandParamsFromCommand(activeCommand),
      () => isCurrent
    );

    isCurrent = false;
    resolveSelection({
      data: {
        payload: { ...activeCommand, status: 'queued' },
      },
    });
    const command = await continuation;

    expect(command.status).toBe('queued');
    expect(SchedulingProviderCommandsAPI.get).not.toHaveBeenCalled();
    expect(store.lastCommand).toBeNull();
    expect(store.ui.isExecuting).toBe(false);
  });

  it.each(['account', 'patient'])(
    'does not confirm a newly staged command after the %s changes',
    async dimension => {
      const pending = deferred();
      SchedulingProviderCommandsAPI.create.mockReturnValueOnce(pending.promise);
      const store = useSchedulingProviderCommandsStore();
      const original = { account: 74, patient: 84 };
      const context = { ...original };
      const request = store.executeConfirmed(
        {
          appointment_id: 20,
          operation: 'create_reception',
          provider: 'medelement',
        },
        {
          pollIntervalMs: 0,
          isCurrent: () =>
            context.account === original.account &&
            context.patient === original.patient,
        }
      );
      context[dimension] += 1;
      pending.resolve({
        data: {
          payload: { ...patientCommand, status: 'awaiting_confirmation' },
        },
      });
      expect((await request).status).toBe('awaiting_confirmation');
      expect(SchedulingProviderCommandsAPI.create).toHaveBeenCalledOnce();
      expect(SchedulingProviderCommandsAPI.confirm).not.toHaveBeenCalled();
      expect(SchedulingProviderCommandsAPI.get).not.toHaveBeenCalled();
      expect(SchedulingProviderCommandsAPI.cancel).not.toHaveBeenCalled();
      expect(store.lastCommand).toBeNull();
    }
  );

  it('does not start a stale client intent or clear current UI state', async () => {
    const store = useSchedulingProviderCommandsStore();
    store.ui.error = { message: 'Current error' };
    expect(
      await store.executeConfirmed(
        { appointment_id: 20, operation: 'create_reception' },
        { isCurrent: () => false }
      )
    ).toBeNull();
    expect(
      await store.confirmExisting(patientCommand, undefined, () => false)
    ).toEqual(patientCommand);
    expect(await store.cancel(patientCommand, () => false)).toEqual(
      patientCommand
    );
    expect(SchedulingProviderCommandsAPI.create).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.confirm).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.cancel).not.toHaveBeenCalled();
    expect(store.ui.error).toEqual({ message: 'Current error' });
  });

  it('keeps an already sent confirmation intact and stops stale polling after navigation', async () => {
    SchedulingProviderCommandsAPI.create.mockResolvedValueOnce({
      data: { payload: { ...patientCommand, status: 'awaiting_confirmation' } },
    });
    const pending = deferred();
    SchedulingProviderCommandsAPI.confirm.mockReturnValueOnce(pending.promise);
    const store = useSchedulingProviderCommandsStore();
    let current = true;
    const request = store.executeConfirmed(
      { appointment_id: 20, operation: 'create_reception' },
      { pollIntervalMs: 0, isCurrent: () => current }
    );
    await Promise.resolve();
    expect(SchedulingProviderCommandsAPI.confirm).toHaveBeenCalledOnce();
    current = false;
    pending.resolve({
      data: { payload: { ...patientCommand, status: 'queued' } },
    });
    expect((await request).status).toBe('queued');
    expect(SchedulingProviderCommandsAPI.create).toHaveBeenCalledOnce();
    expect(SchedulingProviderCommandsAPI.confirm).toHaveBeenCalledOnce();
    expect(SchedulingProviderCommandsAPI.get).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.cancel).not.toHaveBeenCalled();
    expect(store.lastCommand).toBeNull();
  });

  it('forwards the captured context through existing confirmation and ignores its late result', async () => {
    const pending = deferred();
    SchedulingProviderCommandsAPI.confirm.mockReturnValueOnce(pending.promise);
    const store = useSchedulingProviderCommandsStore();
    let current = true;
    const request = store.confirmExisting(
      { ...patientCommand, status: 'awaiting_confirmation' },
      undefined,
      () => current
    );
    current = false;
    pending.resolve({
      data: { payload: { ...patientCommand, status: 'queued' } },
    });
    expect((await request).status).toBe('queued');
    expect(SchedulingProviderCommandsAPI.confirm).toHaveBeenCalledOnce();
    expect(SchedulingProviderCommandsAPI.get).not.toHaveBeenCalled();
    expect(store.lastCommand).toBeNull();
  });

  it('does not let an old create finalizer reset a replacement patient operation', async () => {
    const creation = deferred();
    const selection = deferred();
    SchedulingProviderCommandsAPI.create.mockReturnValueOnce(creation.promise);
    SchedulingProviderCommandsAPI.selectPatient.mockReturnValueOnce(
      selection.promise
    );
    const store = useSchedulingProviderCommandsStore();
    const first = store.executeConfirmed(
      { appointment_id: 20, operation: 'create_reception' },
      { pollIntervalMs: 0 }
    );
    const replacement = store.selectPatient(
      { ...patientCommand, id: 92 },
      'new-selection-token'
    );
    creation.resolve({
      data: { payload: { ...patientCommand, status: 'awaiting_confirmation' } },
    });
    await first;
    expect(store.ui.isExecuting).toBe(true);
    expect(SchedulingProviderCommandsAPI.confirm).not.toHaveBeenCalled();
    selection.resolve({
      data: { payload: { ...patientCommand, id: 92, status: 'succeeded' } },
    });
    await replacement;
    expect(store.lastCommand.id).toBe(92);
    expect(store.ui.isExecuting).toBe(false);
    expect(SchedulingProviderCommandsAPI.create).toHaveBeenCalledOnce();
    expect(SchedulingProviderCommandsAPI.selectPatient).toHaveBeenCalledOnce();
  });

  it.each(['success', 'failure'])(
    'keeps a replacement provider dialog after a late cancel %s',
    async outcome => {
      const pending = deferred();
      SchedulingProviderCommandsAPI.cancel.mockReturnValueOnce(pending.promise);
      const store = useSchedulingProviderCommandsStore();
      const action = { command: patientCommand, account: 74, patient: 84 };
      let activeAction = action;
      const isCurrent = () => activeAction === action;
      const close = vi.fn();
      const alert = vi.fn();
      const reset = vi.fn(() => {
        activeAction = null;
      });
      const request = runCurrentCalendarProviderAction({
        run: () => store.cancel(patientCommand, isCurrent),
        isCurrent,
        onSuccess: close,
        onError: alert,
        onFinally: reset,
      });
      const replacement = {
        command: { ...patientCommand, id: 92 },
        account: 75,
        patient: 85,
      };
      activeAction = replacement;
      store.lastCommand = replacement.command;
      if (outcome === 'success')
        pending.resolve({
          data: { payload: { ...patientCommand, status: 'cancelled' } },
        });
      else pending.reject(new Error('Network error'));
      expect(await request).toBeNull();
      expect(SchedulingProviderCommandsAPI.cancel).toHaveBeenCalledOnce();
      expect(close).not.toHaveBeenCalled();
      expect(alert).not.toHaveBeenCalled();
      expect(reset).not.toHaveBeenCalled();
      expect(activeAction).toBe(replacement);
      expect(store.lastCommand.id).toBe(92);
    }
  );

  it('does not let a failed old cancellation reset or publish an error into a newer operation', async () => {
    const cancellation = deferred();
    const selection = deferred();
    SchedulingProviderCommandsAPI.cancel.mockReturnValueOnce(
      cancellation.promise
    );
    SchedulingProviderCommandsAPI.selectPatient.mockReturnValueOnce(
      selection.promise
    );
    const store = useSchedulingProviderCommandsStore();
    const first = store.cancel(patientCommand);
    const rejection = expect(first).rejects.toMatchObject({
      message: 'Old cancel failed',
    });
    const replacement = store.selectPatient(
      { ...patientCommand, id: 92 },
      'new-selection-token'
    );
    cancellation.reject(new Error('Old cancel failed'));
    await rejection;
    expect(store.ui.isExecuting).toBe(true);
    expect(store.ui.error).toBeNull();
    selection.resolve({
      data: { payload: { ...patientCommand, id: 92, status: 'succeeded' } },
    });
    await replacement;
    expect(store.lastCommand.id).toBe(92);
    expect(store.ui.isExecuting).toBe(false);
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
