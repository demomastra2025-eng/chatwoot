import { reactive } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import { generateMutationTypes } from 'dashboard/store/storeFactory';

const ASSISTANT_MUTATIONS = generateMutationTypes('CaptainAssistant');

// Turns an AI agent on or off from the gallery card or the agent page header.
// Every agent has the same switch. Returns false on any failure so the
// caller's Switch falls back to the stored value.
export const useAgentActiveToggle = () => {
  const store = useStore();
  const { t } = useI18n();
  const togglingIds = reactive({});

  const isToggling = id => Boolean(togglingIds[id]);

  const alertFailure = () => {
    useAlert(t('CAPTAIN.GALLERY.ERRORS.TOGGLE_FAILED'));
  };

  const refreshAssistant = async (id, savedAssistant) => {
    try {
      await store.dispatch('captainAssistants/show', id);
    } catch {
      // The change is saved; keep the list in step with the update response
      // when the follow-up read fails.
      if (savedAssistant?.id) {
        store.commit(
          `captainAssistants/${ASSISTANT_MUTATIONS.UPSERT}`,
          savedAssistant
        );
      }
    }
  };

  const setActive = async (assistant, active) => {
    const id = assistant?.id;
    if (!id || isToggling(id)) return false;

    togglingIds[id] = true;
    try {
      let response;
      try {
        response = await CaptainAssistantAPI.update(id, {
          active: Boolean(active),
        });
      } catch {
        alertFailure();
        return false;
      }

      await refreshAssistant(id, response?.data);
      return true;
    } finally {
      delete togglingIds[id];
    }
  };

  return { setActive, isToggling };
};

export default useAgentActiveToggle;
