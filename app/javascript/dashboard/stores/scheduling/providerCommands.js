import { defineStore } from 'pinia';

import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';

import { extractSchedulingError, normalizePayload } from './shared';

const TERMINAL_STATUSES = new Set([
  'awaiting_patient_creation',
  'awaiting_patient_selection',
  'awaiting_phone_refresh',
  'cancelled',
  'declined',
  'failed',
  'succeeded',
]);

const pause = milliseconds => {
  if (milliseconds <= 0) return Promise.resolve();

  return new Promise(resolve => {
    window.setTimeout(resolve, milliseconds);
  });
};

const createStaleProviderContextError = () => {
  const error = new Error('The provider command account context changed');
  error.code = 'stale_provider_context';
  return error;
};

const assertCurrentProviderContext = isCurrent => {
  if (!isCurrent()) throw createStaleProviderContextError();
};

const pollProviderCommand = async (
  command,
  { attempt = 0, isCurrent, maxPollAttempts, pollIntervalMs }
) => {
  if (TERMINAL_STATUSES.has(command.status) || attempt >= maxPollAttempts) {
    return command;
  }

  await pause(pollIntervalMs);
  assertCurrentProviderContext(isCurrent);
  const showResponse = command.provider
    ? await SchedulingProviderCommandsAPI.get(command.id, {
        provider: command.provider,
      })
    : await SchedulingProviderCommandsAPI.get(command.id);
  assertCurrentProviderContext(isCurrent);

  return pollProviderCommand(normalizePayload(showResponse.data), {
    attempt: attempt + 1,
    isCurrent,
    maxPollAttempts,
    pollIntervalMs,
  });
};

export const buildProviderCommandIdempotencyKey = (
  operation,
  appointmentId
) => {
  const nonce =
    window.crypto?.randomUUID?.() ||
    `${Date.now()}-${Math.random().toString(36).slice(2)}`;

  return `scheduling-dashboard:${operation}:${appointmentId}:${nonce}`;
};

const normalizeIntentTimestamp = value => {
  if (!value) return '';

  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp)
    ? String(value)
    : new Date(timestamp).toISOString();
};

export const buildProviderCommandParamsFromCommand = command => {
  const params = {
    appointment_id: command.appointmentId,
    operation: command.operation,
    provider: command.provider || 'medelement',
  };

  if (command.operation === 'remove_reception') return params;

  params.company_cabinet_code = command.companyCabinetCode;
  if (command.operation === 'move_reception') {
    params.desired_ends_at = command.desiredEndsAt;
    params.desired_starts_at = command.desiredStartsAt;
  }

  return params;
};

export const providerCommandIntentMatches = (params, command) => {
  if (!params || !command) return false;

  const authoritative = buildProviderCommandParamsFromCommand(command);
  if (
    Number(params.appointment_id) !== Number(authoritative.appointment_id) ||
    params.operation !== authoritative.operation ||
    (params.provider || 'medelement') !== authoritative.provider
  ) {
    return false;
  }

  if (authoritative.operation === 'remove_reception') return true;
  if (
    String(params.company_cabinet_code || '') !==
    String(authoritative.company_cabinet_code || '')
  ) {
    return false;
  }

  return (
    authoritative.operation !== 'move_reception' ||
    (normalizeIntentTimestamp(params.desired_starts_at) ===
      normalizeIntentTimestamp(authoritative.desired_starts_at) &&
      normalizeIntentTimestamp(params.desired_ends_at) ===
        normalizeIntentTimestamp(authoritative.desired_ends_at))
  );
};

export const buildProviderCommandAction = (action, command) => {
  if (!command) return { ...action, requestedParams: action.params };

  return {
    ...action,
    command,
    intentMismatch: !providerCommandIntentMatches(action.params, command),
    params: buildProviderCommandParamsFromCommand(command),
    requestedParams: action.params,
  };
};

const assertProviderCommandIntent = (command, expectedIntent) => {
  if (
    !expectedIntent ||
    providerCommandIntentMatches(expectedIntent, command)
  ) {
    return;
  }

  const error = new Error(
    'The active MedElement command does not match the requested action'
  );
  error.code = 'provider_command_intent_mismatch';
  throw error;
};

export const useSchedulingProviderCommandsStore = defineStore(
  'schedulingProviderCommands',
  {
    state: () => ({
      lastCommand: null,
      requestGeneration: 0,
      ui: {
        error: null,
        isExecuting: false,
      },
    }),

    actions: {
      resetForAccountChange() {
        this.requestGeneration += 1;
        this.lastCommand = null;
        this.ui.error = null;
        this.ui.isExecuting = false;
      },

      async findActive({ appointmentId, provider }) {
        const requestGeneration = this.requestGeneration;
        const response = await SchedulingProviderCommandsAPI.list({
          activeOnly: true,
          appointmentId,
          ...(provider ? { provider } : {}),
        });
        assertCurrentProviderContext(
          () => requestGeneration === this.requestGeneration
        );
        return normalizePayload(response.data)?.[0] || null;
      },

      async loadPatientCandidates(command) {
        const requestGeneration = this.requestGeneration;
        const response = command.provider
          ? await SchedulingProviderCommandsAPI.patientCandidates(command.id, {
              provider: command.provider,
            })
          : await SchedulingProviderCommandsAPI.patientCandidates(command.id);
        assertCurrentProviderContext(
          () => requestGeneration === this.requestGeneration
        );
        return normalizePayload(response.data);
      },

      async resumePatientAction(command, action, expectedIntent) {
        assertProviderCommandIntent(command, expectedIntent);
        const requestGeneration = this.requestGeneration;
        const isCurrent = () => requestGeneration === this.requestGeneration;
        this.ui.error = null;
        this.ui.isExecuting = true;
        try {
          assertCurrentProviderContext(isCurrent);
          const response = await action();
          assertCurrentProviderContext(isCurrent);
          let resumedCommand = normalizePayload(response.data);
          resumedCommand = await pollProviderCommand(resumedCommand, {
            isCurrent,
            maxPollAttempts: 75,
            pollIntervalMs: 1000,
          });
          this.lastCommand = resumedCommand;
          return resumedCommand;
        } catch (error) {
          if (error?.code === 'stale_provider_context') throw error;
          this.ui.error = extractSchedulingError(error);
          throw this.ui.error;
        } finally {
          if (isCurrent()) this.ui.isExecuting = false;
        }
      },

      selectPatient(command, token, expectedIntent) {
        return this.resumePatientAction(
          command,
          () =>
            SchedulingProviderCommandsAPI.selectPatient(command.id, {
              ...(command.provider ? { provider: command.provider } : {}),
              token,
            }),
          expectedIntent
        );
      },

      confirmPatientCreation(command, expectedIntent) {
        return this.resumePatientAction(
          command,
          () =>
            command.provider
              ? SchedulingProviderCommandsAPI.confirmPatientCreation(
                  command.id,
                  { provider: command.provider }
                )
              : SchedulingProviderCommandsAPI.confirmPatientCreation(
                  command.id
                ),
          expectedIntent
        );
      },

      retryPhoneMismatch(command, expectedIntent) {
        return this.resumePatientAction(
          command,
          () =>
            SchedulingProviderCommandsAPI.retry(command.id, {
              provider: command.provider,
            }),
          expectedIntent
        );
      },

      confirmExisting(command, expectedIntent) {
        return this.resumePatientAction(
          command,
          () =>
            command.provider
              ? SchedulingProviderCommandsAPI.confirm(command.id, {
                  provider: command.provider,
                  automatic: true,
                })
              : SchedulingProviderCommandsAPI.confirm(command.id, {
                  automatic: true,
                }),
          expectedIntent
        );
      },

      async cancel(command) {
        const requestGeneration = this.requestGeneration;
        const response = command.provider
          ? await SchedulingProviderCommandsAPI.cancel(command.id, {
              provider: command.provider,
            })
          : await SchedulingProviderCommandsAPI.cancel(command.id);
        assertCurrentProviderContext(
          () => requestGeneration === this.requestGeneration
        );
        this.lastCommand = normalizePayload(response.data);
        return this.lastCommand;
      },

      async executeConfirmed(
        commandParams,
        { maxPollAttempts = 75, pollIntervalMs = 1000 } = {}
      ) {
        const requestGeneration = this.requestGeneration;
        const isCurrent = () => requestGeneration === this.requestGeneration;
        this.ui.error = null;
        this.ui.isExecuting = true;

        try {
          assertCurrentProviderContext(isCurrent);
          const createResponse = await SchedulingProviderCommandsAPI.create({
            ...commandParams,
            idempotency_key:
              commandParams.idempotency_key ||
              buildProviderCommandIdempotencyKey(
                commandParams.operation,
                commandParams.appointment_id
              ),
          });
          assertCurrentProviderContext(isCurrent);
          let command = normalizePayload(createResponse.data);

          const confirmResponse = command.provider
            ? await SchedulingProviderCommandsAPI.confirm(command.id, {
                provider: command.provider,
                automatic: true,
              })
            : await SchedulingProviderCommandsAPI.confirm(command.id, {
                automatic: true,
              });
          assertCurrentProviderContext(isCurrent);
          command = normalizePayload(confirmResponse.data);
          this.lastCommand = command;

          command = await pollProviderCommand(command, {
            isCurrent,
            maxPollAttempts,
            pollIntervalMs,
          });
          this.lastCommand = command;

          return command;
        } catch (error) {
          if (error?.code === 'stale_provider_context') throw error;
          this.ui.error = extractSchedulingError(error);
          throw this.ui.error;
        } finally {
          if (isCurrent()) this.ui.isExecuting = false;
        }
      },
    },
  }
);
