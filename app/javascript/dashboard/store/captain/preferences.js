import { defineStore } from 'pinia';
import CaptainPreferencesAPI from 'dashboard/api/captain/preferences';

export const useCaptainConfigStore = defineStore('captainConfig', {
  state: () => ({
    providers: {},
    models: {},
    features: {},
    runtime: {},
    observability: {},
    runtimeMetadata: {},
    uiFlags: {
      isFetching: false,
      isRefreshingOpenRouterModels: false,
    },
  }),

  getters: {
    getProviders: state => state.providers,
    getModels: state => state.models,
    getFeatures: state => state.features,
    getRuntime: state => state.runtime,
    getObservability: state => state.observability,
    getRuntimeMetadata: state => state.runtimeMetadata,
    getUIFlags: state => state.uiFlags,
    getModelsForFeature: state => featureKey => {
      const feature = state.features[featureKey];
      const models = feature?.models || [];

      const providerOrder = {
        openai: 0,
        anthropic: 1,
        gemini: 2,
        openrouter: 3,
      };

      return [...models].sort((a, b) => {
        // Move coming_soon items to the end
        if (a.coming_soon && !b.coming_soon) return 1;
        if (!a.coming_soon && b.coming_soon) return -1;

        // Sort by provider
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
      this.runtimeMetadata = data.runtime_metadata || {};
    },

    async fetch() {
      this.uiFlags.isFetching = true;
      try {
        const response = await CaptainPreferencesAPI.get();
        this.applyPayload(response.data);
      } catch (error) {
        // Ignore error
      } finally {
        this.uiFlags.isFetching = false;
      }
    },

    async updatePreferences(data) {
      const response = await CaptainPreferencesAPI.updatePreferences(data);
      this.applyPayload(response.data);
    },

    async refreshOpenRouterModels() {
      this.uiFlags.isRefreshingOpenRouterModels = true;
      try {
        const response = await CaptainPreferencesAPI.refreshOpenRouterModels();
        this.applyPayload(response.data);
        return response;
      } catch (error) {
        if (error?.response?.data) {
          this.applyPayload(error.response.data);
        }
        throw error;
      } finally {
        this.uiFlags.isRefreshingOpenRouterModels = false;
      }
    },
  },
});
