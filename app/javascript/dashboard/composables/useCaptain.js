import { computed } from 'vue';
import { useMapGetter, useStore } from 'dashboard/composables/store.js';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import { useCamelCase } from 'dashboard/composables/useTransformKeys';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

export function useCaptain() {
  const store = useStore();
  const { t } = useI18n();
  const { isCloudFeatureEnabled, currentAccount, isOnChatwootCloud } =
    useAccount();
  const { isEnterprise } = useConfig();
  const uiFlags = useMapGetter('accounts/getUIFlags');

  // === Feature Flags ===
  const captainEnabled = computed(() => {
    return isCloudFeatureEnabled(FEATURE_FLAGS.CAPTAIN);
  });

  // === Limits (Enterprise) ===
  const captainLimits = computed(() => {
    return currentAccount.value?.limits?.captain;
  });

  const documentLimits = computed(() => {
    if (captainLimits.value?.documents) {
      return useCamelCase(captainLimits.value.documents);
    }
    return null;
  });

  const responseLimits = computed(() => {
    if (captainLimits.value?.responses) {
      return useCamelCase(captainLimits.value.responses);
    }
    return null;
  });

  const tokenLimits = computed(() => {
    if (captainLimits.value?.tokens) {
      return useCamelCase(captainLimits.value.tokens);
    }
    return null;
  });

  const isFetchingLimits = computed(() => uiFlags.value.isFetchingLimits);

  const fetchLimits = async ({ silent = true } = {}) => {
    if (isEnterprise && isOnChatwootCloud.value) {
      try {
        return await store.dispatch('accounts/limits', { silent });
      } catch (error) {
        useAlert(error.message || t('GENERAL_SETTINGS.UPDATE.ERROR'));
        return null;
      }
    }

    return Promise.resolve();
  };

  return {
    // Feature flags
    captainEnabled,

    // Limits (Enterprise)
    captainLimits,
    documentLimits,
    responseLimits,
    tokenLimits,
    fetchLimits,
    isFetchingLimits,
  };
}
