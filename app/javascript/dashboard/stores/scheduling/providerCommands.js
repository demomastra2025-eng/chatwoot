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

const pollProviderCommand = async (
  command,
  { attempt = 0, maxPollAttempts, pollIntervalMs }
) => {
  if (TERMINAL_STATUSES.has(command.status) || attempt >= maxPollAttempts) {
    return command;
  }

  await pause(pollIntervalMs);
  const showResponse = command.provider
    ? await SchedulingProviderCommandsAPI.get(command.id, {
        provider: command.provider,
      })
    : await SchedulingProviderCommandsAPI.get(command.id);

  return pollProviderCommand(normalizePayload(showResponse.data), {
    attempt: attempt + 1,
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
      ui: {
        error: null,
        isExecuting: false,
      },
    }),

    actions: {
      async findActive({ appointmentId, provider }) {
        const response = await SchedulingProviderCommandsAPI.list({
          activeOnly: true,
          appointmentId,
          ...(provider ? { provider } : {}),
        });
        return normalizePayload(response.data)?.[0] || null;
      },

      async loadPatientCandidates(command) {
        const response = command.provider
          ? await SchedulingProviderCommandsAPI.patientCandidates(command.id, {
              provider: command.provider,
            })
          : await SchedulingProviderCommandsAPI.patientCandidates(command.id);
        return normalizePayload(response.data);
      },

      async resumePatientAction(command, action, expectedIntent) {
        assertProviderCommandIntent(command, expectedIntent);
        this.ui.error = null;
        this.ui.isExecuting = true;
        try {
          const response = await action();
          let resumedCommand = normalizePayload(response.data);
          resumedCommand = await pollProviderCommand(resumedCommand, {
            maxPollAttempts: 75,
            pollIntervalMs: 1000,
          });
          this.lastCommand = resumedCommand;
          return resumedCommand;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw this.ui.error;
        } finally {
          this.ui.isExecuting = false;
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
        const response = command.provider
          ? await SchedulingProviderCommandsAPI.cancel(command.id, {
              provider: command.provider,
            })
          : await SchedulingProviderCommandsAPI.cancel(command.id);
        this.lastCommand = normalizePayload(response.data);
        return this.lastCommand;
      },

      async executeConfirmed(
        commandParams,
        { maxPollAttempts = 75, pollIntervalMs = 1000 } = {}
      ) {
        this.ui.error = null;
        this.ui.isExecuting = true;

        try {
          const createResponse = await SchedulingProviderCommandsAPI.create({
            ...commandParams,
            idempotency_key:
              commandParams.idempotency_key ||
              buildProviderCommandIdempotencyKey(
                commandParams.operation,
                commandParams.appointment_id
              ),
          });
          let command = normalizePayload(createResponse.data);

          const confirmResponse = command.provider
            ? await SchedulingProviderCommandsAPI.confirm(command.id, {
                provider: command.provider,
                automatic: true,
              })
            : await SchedulingProviderCommandsAPI.confirm(command.id, {
                automatic: true,
              });
          command = normalizePayload(confirmResponse.data);
          this.lastCommand = command;

          command = await pollProviderCommand(command, {
            maxPollAttempts,
            pollIntervalMs,
          });
          this.lastCommand = command;

          return command;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw this.ui.error;
        } finally {
          this.ui.isExecuting = false;
        }
      },
    },
  }
);
