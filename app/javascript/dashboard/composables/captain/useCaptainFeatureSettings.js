import { useStore } from 'dashboard/composables/store';
import { useCaptainConfigStore } from 'dashboard/store/captain/preferences';

// "Text improvement" (reply-box AI writing tools, Cmd+K AI Assist) is stored
// under its own captain_features key, so a legacy captain_features.editor
// value from the old per-feature switch never turns the tools off.
export const TEXT_IMPROVEMENT_SETTING_KEY = 'text_improvement';

// Saves captain_features switches (AI settings, Settings > Conversations) and
// refreshes the current account, so the reply box, Cmd+K and label
// suggestions of this tab follow the change without a reload.
export function useCaptainFeatureSettings() {
  const store = useStore();
  const captainConfigStore = useCaptainConfigStore();

  const saveCaptainFeatures = async captainFeatures => {
    await captainConfigStore.updatePreferences({
      captain_features: captainFeatures,
    });
    await store.dispatch('accounts/get');
  };

  const saveTextImprovement = enabled =>
    saveCaptainFeatures({ [TEXT_IMPROVEMENT_SETTING_KEY]: enabled });

  return { saveCaptainFeatures, saveTextImprovement };
}
