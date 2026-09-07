import CrmTaskTypesAPI from 'dashboard/api/crm/taskTypes';
import { extractCrmError, normalizePayload } from './shared';

const states = new WeakMap();
const accountId = () => String(CrmTaskTypesAPI.accountIdFromRoute || '');
const isCurrent = (store, state) =>
  states.get(store) === state && accountId() === state.accountId;

const stateFor = store => {
  const id = accountId();
  const previous = states.get(store);
  if (previous?.accountId === id) return previous;
  const state = {
    accountId: id,
    generation: 0,
    load: null,
    journal: [],
    pendingWrites: 0,
    writes: Promise.resolve(),
  };
  states.set(store, state);
  store.taskTypes = [];
  store.ui.isLoadingTaskTypes = false;
  store.ui.isSavingTaskCatalog = false;
  store.ui.taskCatalogError = null;
  return state;
};

// Every GET is a full catalogue. Only overlapping reads are cached. Confirmed
// mutations are replayed over an older GET, including mutations of nested rows.
export const loadTaskCatalog = store => {
  const state = stateFor(store);
  if (state.load) return state.load;
  state.generation += 1;
  const generation = state.generation;
  state.journal = [];
  store.ui.isLoadingTaskTypes = true;
  store.ui.taskCatalogError = null;
  state.load = (async () => {
    try {
      const { data } = await Promise.resolve().then(() =>
        isCurrent(store, state) ? CrmTaskTypesAPI.get() : { data: [] }
      );
      if (!isCurrent(store, state)) return [];
      store.taskTypes = state.journal.reduce(
        (types, apply) => apply(types),
        normalizePayload(data)
      );
      return store.taskTypes;
    } catch (error) {
      if (!isCurrent(store, state) || generation !== state.generation) {
        return isCurrent(store, state) ? store.taskTypes : [];
      }
      store.ui.taskCatalogError = extractCrmError(error);
      throw error;
    } finally {
      state.load = null;
      state.journal = [];
      if (isCurrent(store, state)) store.ui.isLoadingTaskTypes = false;
    }
  })();
  return state.load;
};

// Serialize catalogue writes within one account: a type response includes its
// outcomes, so it must not overwrite a newer, independently saved outcome.
export const mutateTaskCatalog = (store, request, applyResponse) => {
  const state = stateFor(store);
  state.generation += 1;
  const generation = state.generation;
  state.pendingWrites += 1;
  store.ui.isSavingTaskCatalog = true;
  store.ui.taskCatalogError = null;
  const operation = state.writes.then(async () => {
    // API clients resolve the route at invocation, not when work was queued.
    try {
      if (!isCurrent(store, state)) return null;
      const response = await request();
      const record = normalizePayload(response.data);
      if (!isCurrent(store, state)) return null;
      const apply = types => applyResponse(types, record);
      store.taskTypes = apply(store.taskTypes);
      if (state.load) state.journal.push(apply);
      return record;
    } catch (error) {
      if (!isCurrent(store, state)) return null;
      if (generation === state.generation) {
        store.ui.taskCatalogError = extractCrmError(error);
      }
      throw error;
    } finally {
      state.pendingWrites -= 1;
      if (isCurrent(store, state)) {
        store.ui.isSavingTaskCatalog = state.pendingWrites > 0;
      }
    }
  });
  state.writes = operation.catch(() => {});
  return operation;
};
