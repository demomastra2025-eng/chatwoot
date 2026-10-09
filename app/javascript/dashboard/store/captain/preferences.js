import { defineStore } from 'pinia';
import CaptainPreferencesAPI from 'dashboard/api/captain/preferences';

const fetchFlightsByStore = new WeakMap();
const PREFERENCES_CACHE_TTL_MS = 30_000;

const currentAccountId = () =>
  String(CaptainPreferencesAPI.accountIdFromRoute || '__default__');

const updateFetchingFlag = store => {
  const accountFlights = fetchFlightsByStore.get(store);
  const activeAccountFlights = accountFlights?.get(currentAccountId());
  store.uiFlags.isFetching = Boolean(
    activeAccountFlights?.full || activeAccountFlights?.metadata
  );
};

export const useCaptainConfigStore = defineStore('captainConfig', {
  state: () => ({
    providers: {},
    models: {},
    features: {},
    runtime: {},
    observability: {},
    providerCredentials: {},
    runtimeMetadata: {},
    activePreferencesAccountId: '',
    loadedPreferencesByAccount: {},
    preferencesFetchedAtByAccount: {},
    uiFlags: {
      isFetching: false,
      fetchError: false,
    },
  }),

  getters: {
    getProviders: state => state.providers,
    getModels: state => state.models,
    getFeatures: state => state.features,
    getRuntime: state => state.runtime,
    getObservability: state => state.observability,
    getProviderCredentials: state => state.providerCredentials,
    getRuntimeMetadata: state => state.runtimeMetadata,
    getUIFlags: state => state.uiFlags,
    getModelsForFeature: state => featureKey => {
      const feature = state.features[featureKey];
      const models = feature?.models || [];

      const providerOrder = {
        openrouter: 0,
        openai: 1,
        anthropic: 2,
        gemini: 3,
      };
      const modelSourcePriority = model => {
        if (model.account_configured) return 0;
        if (model.provider === 'openrouter' && model.global_configured) {
          return 1;
        }
        if (model.global_configured) return 2;
        return 3;
      };

      return [...models]
        .filter(model => model.provider_configured !== false)
        .sort((a, b) => {
          // Move coming_soon items to the end
          if (a.coming_soon && !b.coming_soon) return 1;
          if (!a.coming_soon && b.coming_soon) return -1;

          const sourceA = modelSourcePriority(a);
          const sourceB = modelSourcePriority(b);
          if (sourceA !== sourceB) return sourceA - sourceB;

          // Prefer OpenRouter as the normal Captain provider platform.
          const providerA = providerOrder[a.provider] ?? 999;
          const providerB = providerOrder[b.provider] ?? 999;
          if (providerA !== providerB) return providerA - providerB;

          // Sort by credit_multiplier (highest first)
          return (b.credit_multiplier || 0) - (a.credit_multiplier || 0);
        });
    },
    getDefaultModelForFeature: state => featureKey => {
      const feature = state.features[featureKey];
      return feature?.default || null;
    },
    getSelectedModelForFeature: state => featureKey => {
      const feature = state.features[featureKey];
      return feature?.selected || feature?.default || null;
    },
  },

  actions: {
    applyPayload(data = {}) {
      this.providers = data.providers || {};
      this.models = data.models || {};
      this.features = data.features || {};
      this.runtime = data.runtime || {};
      this.observability = data.observability || {};
      this.providerCredentials = data.provider_credentials || {};
      this.runtimeMetadata = data.runtime_metadata || {};
    },

    activateAccount(accountId) {
      if (this.activePreferencesAccountId === accountId) return;

      // The store only keeps one account's payload at a time. Drop it before
      // loading another workspace so its settings are never shown as the new
      // workspace's values while the request is pending.
      this.applyPayload();
      this.activePreferencesAccountId = accountId;
      delete this.loadedPreferencesByAccount[accountId];
      delete this.preferencesFetchedAtByAccount[accountId];
      this.uiFlags.fetchError = false;
    },

    async fetch({
      clientMetadataOnly = false,
      force = false,
      accountId = currentAccountId(),
    } = {}) {
      accountId = String(accountId || '__default__');
      const isCurrentAccountRequest = currentAccountId() === accountId;
      const wasActiveAccount = this.activePreferencesAccountId === accountId;
      if (isCurrentAccountRequest) {
        this.activateAccount(accountId);
        updateFetchingFlag(this);
      }

      const loadedLevel =
        isCurrentAccountRequest && wasActiveAccount
          ? this.loadedPreferencesByAccount[accountId]
          : null;
      const isCacheFresh =
        Date.now() - (this.preferencesFetchedAtByAccount[accountId] || 0) <
        PREFERENCES_CACHE_TTL_MS;
      if (
        isCurrentAccountRequest &&
        !force &&
        isCacheFresh &&
        (loadedLevel === 'full' || (clientMetadataOnly && loadedLevel))
      ) {
        return null;
      }

      let accountFlights = fetchFlightsByStore.get(this);
      if (!accountFlights) {
        accountFlights = new Map();
        fetchFlightsByStore.set(this, accountFlights);
      }
      const accountFlight = accountFlights.get(accountId) || {};

      if (accountFlight.full) return accountFlight.full;
      if (clientMetadataOnly && accountFlight.metadata) {
        return accountFlight.metadata;
      }
      if (!clientMetadataOnly && accountFlight.metadata) {
        await accountFlight.metadata;
        if (currentAccountId() !== accountId) return null;
        return this.fetch({
          clientMetadataOnly: false,
          force: true,
          accountId,
        });
      }

      this.uiFlags.fetchError = false;

      const request = (async () => {
        try {
          const response = await CaptainPreferencesAPI.get({
            client_metadata_only: clientMetadataOnly,
          });
          // Do not let a slow response for a previous workspace replace the
          // preferences now shown for the account in the URL.
          if (currentAccountId() === accountId) {
            this.applyPayload(response.data);
            this.activePreferencesAccountId = accountId;
            this.loadedPreferencesByAccount[accountId] = clientMetadataOnly
              ? 'metadata'
              : 'full';
            this.preferencesFetchedAtByAccount[accountId] = Date.now();
          }
          return response;
        } catch (error) {
          if (currentAccountId() === accountId) this.uiFlags.fetchError = true;
          return null;
        } finally {
          const currentFlights = fetchFlightsByStore.get(this)?.get(accountId);
          if (currentFlights?.full === request) {
            delete currentFlights.full;
          }
          if (currentFlights?.metadata === request) {
            delete currentFlights.metadata;
          }
          if (
            currentFlights &&
            !currentFlights.full &&
            !currentFlights.metadata
          ) {
            fetchFlightsByStore.get(this).delete(accountId);
          }
          updateFetchingFlag(this);
        }
      })();

      accountFlight[clientMetadataOnly ? 'metadata' : 'full'] = request;
      accountFlights.set(accountId, accountFlight);
      updateFetchingFlag(this);
      return request;
    },

    async updatePreferences(data, { applyPayload = true } = {}) {
      const accountId = currentAccountId();
      const response = await CaptainPreferencesAPI.updatePreferences(data);
      if (applyPayload && currentAccountId() === accountId) {
        this.applyPayload(response.data);
        this.activePreferencesAccountId = accountId;
        this.loadedPreferencesByAccount[accountId] = 'full';
        this.preferencesFetchedAtByAccount[accountId] = Date.now();
      }

      return response;
    },

    patchRuntime(data = {}) {
      this.runtime = {
        ...this.runtime,
        ...data,
      };
    },

    patchRuntimeMetadata(data = {}) {
      this.runtimeMetadata = {
        ...this.runtimeMetadata,
        ...data,
      };
    },

    patchFeature(featureKey, data = {}) {
      if (!featureKey || !data) return;

      this.features = {
        ...this.features,
        [featureKey]: {
          ...(this.features[featureKey] || {}),
          ...data,
        },
      };
    },
  },
});
