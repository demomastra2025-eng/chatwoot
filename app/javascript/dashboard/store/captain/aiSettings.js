import { defineStore } from 'pinia';
import CaptainAiSettingsAPI from 'dashboard/api/captain/aiSettings';
import { AI_SETTINGS_SECTIONS } from 'dashboard/helper/captainAiSettings';

const fetchFlightsByStore = new WeakMap();
const AI_SETTINGS_CACHE_TTL_MS = 30_000;

const currentAccountId = () =>
  String(CaptainAiSettingsAPI.accountIdFromRoute || '__default__');

const accountFlights = store => {
  let flights = fetchFlightsByStore.get(store);
  if (!flights) {
    flights = new Map();
    fetchFlightsByStore.set(store, flights);
  }
  return flights;
};

const isPlainObject = value =>
  Boolean(value) && typeof value === 'object' && !Array.isArray(value);

const hasSettingsSections = value =>
  isPlainObject(value) &&
  [...AI_SETTINGS_SECTIONS, 'availability'].some(section =>
    isPlainObject(value[section])
  );

// Accept the contract body and a `{ settings: {...} }` wrapper.
const unwrapPayload = data => {
  if (hasSettingsSections(data)) return data;
  if (hasSettingsSections(data?.settings)) return data.settings;
  return null;
};

const normalizeError = error => {
  if (typeof error === 'string') {
    return { field: null, code: '', message: error };
  }
  return {
    field: error?.field ?? error?.path ?? null,
    code: error?.code ?? '',
    message: error?.message ?? '',
  };
};

// Always a list of { field, code, message }, whatever the server answered.
const errorsFromResponse = error => {
  const data = error?.response?.data;
  if (Array.isArray(data?.errors)) return data.errors.map(normalizeError);
  const status = error?.response?.status;
  const message =
    data?.message ||
    data?.error ||
    (typeof data?.errors === 'string' ? data.errors : '') ||
    error?.message ||
    '';
  let code = data?.code || 'network_error';
  if (!data?.code && status) code = `http_${status}`;
  return [{ field: null, code, message }];
};

export const useCaptainAiSettingsStore = defineStore('captainAiSettings', {
  state: () => ({
    // Raw GET payload, including the read-only `availability`.
    settings: null,
    accountId: '',
    fetchedAt: 0,
    uiFlags: {
      isFetching: false,
      isSaving: false,
      fetchError: false,
    },
    errors: [],
  }),

  getters: {
    getSettings: state => state.settings,
    getAvailability: state => state.settings?.availability || {},
    getUIFlags: state => state.uiFlags,
    getErrors: state => state.errors,
  },

  actions: {
    activateAccount(accountId) {
      if (this.accountId === accountId) return;
      // Never show one workspace's settings while another one is loading.
      this.settings = null;
      this.fetchedAt = 0;
      this.accountId = accountId;
      this.errors = [];
      this.uiFlags.fetchError = false;
      this.uiFlags.isFetching = false;
    },

    // Returns the settings (or null on failure). Never throws.
    async fetch({ force = false } = {}) {
      const accountId = currentAccountId();
      this.activateAccount(accountId);

      const isCacheFresh =
        Date.now() - this.fetchedAt < AI_SETTINGS_CACHE_TTL_MS;
      if (!force && this.settings && isCacheFresh) return this.settings;

      const flights = accountFlights(this);
      if (flights.has(accountId)) return flights.get(accountId);

      this.uiFlags.isFetching = true;
      this.uiFlags.fetchError = false;
      const request = (async () => {
        try {
          const response = await CaptainAiSettingsAPI.get();
          if (currentAccountId() !== accountId) return null;
          this.settings = unwrapPayload(response?.data) || {};
          this.fetchedAt = Date.now();
          this.errors = [];
          return this.settings;
        } catch (error) {
          if (currentAccountId() === accountId) {
            this.uiFlags.fetchError = true;
            this.errors = errorsFromResponse(error);
          }
          return null;
        } finally {
          flights.delete(accountId);
          if (currentAccountId() === accountId) {
            this.uiFlags.isFetching = false;
          }
        }
      })();
      flights.set(accountId, request);
      return request;
    },

    // PATCH a partial payload. Resolves { ok: true, settings } or
    // { ok: false, errors: [{ field, code, message }] }. Never throws.
    async save(patchBody = {}) {
      const accountId = currentAccountId();
      this.activateAccount(accountId);
      this.uiFlags.isSaving = true;
      this.errors = [];
      try {
        const response = await CaptainAiSettingsAPI.update(patchBody);
        const payload = unwrapPayload(response?.data);
        const settings = {
          ...(this.settings || {}),
          ...(payload || patchBody),
        };
        if (currentAccountId() === accountId) {
          this.settings = settings;
          this.fetchedAt = Date.now();
        }
        return { ok: true, settings };
      } catch (error) {
        const errors = errorsFromResponse(error);
        if (currentAccountId() === accountId) this.errors = errors;
        return { ok: false, errors };
      } finally {
        this.uiFlags.isSaving = false;
      }
    },
  },
});
