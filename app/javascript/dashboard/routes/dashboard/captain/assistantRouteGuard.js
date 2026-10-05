import store from '../../../store';
import { isInternalAssistant } from '../../../store/captain/assistant';

// Internal assistants are gone from the product, so a link to one of their
// pages (an old bookmark, an observability event) behaves like a missing
// agent: the person lands on the list of agents, never on a reduced page.
export const redirectHiddenAssistant = async to => {
  const assistantId = Number(to.params?.assistantId);
  if (!assistantId) {
    return true;
  }

  const loaded = store.state.captainAssistants?.records?.find(
    record => record.id === assistantId
  );
  let assistant = loaded;

  if (!assistant) {
    try {
      assistant = await store.dispatch('captainAssistants/show', assistantId);
    } catch {
      // A failed lookup keeps the page as it was: it shows its own error.
      return true;
    }
  }

  if (!isInternalAssistant(assistant)) {
    return true;
  }

  return {
    name: 'captain_assistants_create_index',
    params: { accountId: to.params.accountId },
    replace: true,
  };
};

export default redirectHiddenAssistant;
