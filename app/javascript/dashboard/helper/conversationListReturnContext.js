const RETURN_PATH_STATE_KEY = 'conversationListReturnPath';
const RETURN_PATH_STORAGE_PREFIX = 'conversation_list_return_path';

const returnPathStorageKey = (accountId, threadId) =>
  `${RETURN_PATH_STORAGE_PREFIX}:${accountId}:${threadId}`;

const validReturnPath = (path, accountId) =>
  typeof path === 'string' &&
  path.startsWith(`/app/accounts/${accountId}/`) &&
  !path.includes('://');

// The return path is a convenience: storage that is blocked, full or throws
// (private mode, quota) must never break opening a thread, so every access is
// guarded and the history state still carries the path.
const defaultStorage = () => {
  try {
    return typeof window === 'undefined' ? undefined : window.sessionStorage;
  } catch {
    return undefined;
  }
};

const writeStoredPath = (storage, key, path) => {
  try {
    storage?.setItem(key, path);
  } catch {
    // Keep navigating with the history state only.
  }
};

const readStoredPath = (storage, key) => {
  try {
    return storage?.getItem(key);
  } catch {
    return undefined;
  }
};

export const rememberConversationListReturnPath = ({
  accountId,
  threadId,
  path,
  storage = defaultStorage(),
}) => {
  if (!validReturnPath(path, accountId)) return {};

  writeStoredPath(storage, returnPathStorageKey(accountId, threadId), path);
  return {
    [RETURN_PATH_STATE_KEY]: {
      accountId: String(accountId),
      threadId: String(threadId),
      path,
    },
  };
};

export const conversationListReturnPath = ({
  accountId,
  threadId,
  historyState = typeof window === 'undefined'
    ? undefined
    : window.history.state,
  storage = defaultStorage(),
}) => {
  const stateContext = historyState?.[RETURN_PATH_STATE_KEY];
  const matchingStateContext =
    stateContext?.accountId === String(accountId) &&
    stateContext?.threadId === String(threadId);
  if (matchingStateContext && validReturnPath(stateContext.path, accountId)) {
    return stateContext.path;
  }

  const storedPath = readStoredPath(
    storage,
    returnPathStorageKey(accountId, threadId)
  );
  return validReturnPath(storedPath, accountId) ? storedPath : undefined;
};
