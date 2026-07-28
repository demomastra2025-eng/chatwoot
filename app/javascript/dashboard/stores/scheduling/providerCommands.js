import { defineStore } from 'pinia';

import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';

import { extractSchedulingError, normalizePayload } from './shared';

const TERMINAL_STATUSES = new Set([
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
  const showResponse = await SchedulingProviderCommandsAPI.get(command.id);

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

          const confirmResponse = await SchedulingProviderCommandsAPI.confirm(
            command.id
          );
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
