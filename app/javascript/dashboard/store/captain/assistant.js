import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import { createStore } from '../storeFactory';

// Only AI agents (customer-facing) exist for the user. The old internal
// assistant rows stay in the database, but the dashboard never shows them:
// the getters below are the single place that hides them, so the list, the
// switcher, the inbox picker and the settings pages only ever see agents.
export const INTERNAL_ASSISTANT_USAGE_MODE = 'internal_assistant';

export const isInternalAssistant = assistant =>
  assistant?.usage_mode === INTERNAL_ASSISTANT_USAGE_MODE;

export default createStore({
  name: 'CaptainAssistant',
  API: CaptainAssistantAPI,
  getters: {
    getRecords: state =>
      state.records
        .filter(record => !isInternalAssistant(record))
        .sort((r1, r2) => r2.id - r1.id),
    getRecord: state => id => {
      const record = state.records.find(item => item.id === Number(id));
      return record && !isInternalAssistant(record) ? record : {};
    },
  },
});
