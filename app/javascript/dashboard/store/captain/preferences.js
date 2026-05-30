import { defineStore } from 'pinia';
import CaptainPreferencesAPI from 'dashboard/api/captain/preferences';

export const useCaptainConfigStore = defineStore('captainConfig', {
  state: () => ({
    providers: {},
    models: {},
    features: {},
    runtime: {},
    observability: {},
    providerCredentials: {},
    runtimeMetadata: {},
    uiFlags: {
      isFetching: false,
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
        openai: 0,
        anthropic: 1,
        gemini: 2,
        openrouter: 3,
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

          // Prefer direct providers; shared OpenRouter remains the common fallback.
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

    async updatePreferences(data, { applyPayload = true } = {}) {
      const response = await CaptainPreferencesAPI.updatePreferences(data);
      if (applyPayload) {
        this.applyPayload(response.data);
      }

      return response;
    },
  },
});
