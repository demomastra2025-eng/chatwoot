import { defineStore } from 'pinia';
import CaptainChannelMatrixAPI from 'dashboard/api/captain/channelMatrix';
import {
  extractMatrixErrors,
  isTextChannel,
} from 'dashboard/helper/captainChannelMatrix';

// Text channels × AI agents (GET/PATCH captain/channel_matrix, admin only).
// Consumers call fetch() only for administrators. The payload is kept raw;
// pages build their own editable draft with toMatrixDraft().

const MATRIX_CACHE_TTL_MS = 30_000;
const fetchFlightsByStore = new WeakMap();

const currentAccountId = () =>
  String(CaptainChannelMatrixAPI.accountIdFromRoute || '__default__');

const flightsFor = store => {
  let flights = fetchFlightsByStore.get(store);
  if (!flights) {
    flights = new Map();
    fetchFlightsByStore.set(store, flights);
  }
  return flights;
};

const isMatrixPayload = data =>
  Boolean(data) && typeof data === 'object' && Array.isArray(data.channels);

const isTextChannelRow = channel => isTextChannel(channel?.channel_type);

// One GET for one account. Never throws: a 403 (non-admin) or a network
// error only sets the fetch error flag.
const loadMatrix = async (store, accountId) => {
  const startRevision = store.revision;
  try {
    const response = await CaptainChannelMatrixAPI.get();
    const data = response?.data;
    if (currentAccountId() !== accountId) return null;
    if (store.revision === startRevision) {
      store.applyMatrix(isMatrixPayload(data) ? data : null);
    }
    return store.matrix;
  } catch (error) {
    if (currentAccountId() === accountId) store.uiFlags.fetchError = true;
    return null;
  }
};

export const useCaptainChannelMatrixStore = defineStore(
  'captainChannelMatrix',
  {
    state: () => ({
      matrix: null,
      uiFlags: {
        isFetching: false,
        isSaving: false,
        fetchError: false,
      },
      errors: [],
      activeAccountId: '',
      fetchedAt: 0,
      // Bumped on every applied payload and account switch, so a slow GET
      // that started earlier never replaces newer data.
      revision: 0,
    }),

    getters: {
      getMatrix: state => state.matrix,
      getChannels: state =>
        (state.matrix?.channels || []).filter(isTextChannelRow),
      getAssistants: state => state.matrix?.assistants || [],
      getDefaultMainAssistantId: state =>
        state.matrix?.default_main_assistant_id ?? null,
      getUIFlags: state => state.uiFlags,
    },

    actions: {
      activateAccount(accountId) {
        if (this.activeAccountId === accountId) return;

        // One account at a time: never show another workspace's channels
        // while the new request is pending.
        this.activeAccountId = accountId;
        this.matrix = null;
        this.errors = [];
        this.fetchedAt = 0;
        this.revision += 1;
        this.uiFlags.fetchError = false;
        this.uiFlags.isFetching = flightsFor(this).has(accountId);
      },

      applyMatrix(data) {
        this.matrix = data;
        this.fetchedAt = Date.now();
        this.revision += 1;
        this.uiFlags.fetchError = false;
      },

      requestMatrix(accountId) {
        const flights = flightsFor(this);
        this.uiFlags.isFetching = true;
        this.uiFlags.fetchError = false;

        const request = loadMatrix(this, accountId).finally(() => {
          if (flights.get(accountId) === request) flights.delete(accountId);
          if (currentAccountId() === accountId) {
            this.uiFlags.isFetching = flights.has(accountId);
          }
        });

        flights.set(accountId, request);
        return request;
      },

      async fetch({ force = false } = {}) {
        const accountId = currentAccountId();
        this.activateAccount(accountId);

        const age = Date.now() - this.fetchedAt;
        if (!force && this.matrix && age < MATRIX_CACHE_TTL_MS) {
          return this.matrix;
        }

        const inFlight = flightsFor(this).get(accountId);
        if (inFlight) return inFlight;

        return this.requestMatrix(accountId);
      },

      async save(patchBody = {}) {
        const accountId = currentAccountId();
        this.activateAccount(accountId);
        this.uiFlags.isSaving = true;
        this.errors = [];

        try {
          const response = await CaptainChannelMatrixAPI.update(patchBody);
          const data = response?.data;
          if (currentAccountId() !== accountId) {
            return { ok: true, matrix: isMatrixPayload(data) ? data : null };
          }

          if (isMatrixPayload(data)) {
            this.applyMatrix(data);
          } else {
            // The contract returns the GET payload; reload if it did not.
            this.revision += 1;
            await this.requestMatrix(accountId);
          }
          return { ok: true, matrix: this.matrix };
        } catch (error) {
          const errors = extractMatrixErrors(error);
          if (currentAccountId() === accountId) this.errors = errors;
          return { ok: false, errors };
        } finally {
          this.uiFlags.isSaving = false;
        }
      },
    },
  }
);
