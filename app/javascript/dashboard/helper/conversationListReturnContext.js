const RETURN_PATH_STATE_KEY = 'conversationListReturnPath';
const RETURN_PATH_STORAGE_PREFIX = 'conversation_list_return_path';

const returnPathStorageKey = (accountId, threadId) =>
  `${RETURN_PATH_STORAGE_PREFIX}:${accountId}:${threadId}`;

const validReturnPath = (path, accountId) =>
  typeof path === 'string' &&
  path.startsWith(`/app/accounts/${accountId}/`) &&
  !path.includes('://');

export const rememberConversationListReturnPath = ({
  accountId,
  threadId,
  path,
  storage = typeof window === 'undefined' ? undefined : window.sessionStorage,
}) => {
  if (!validReturnPath(path, accountId)) return {};

  storage?.setItem(returnPathStorageKey(accountId, threadId), path);
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
  storage = typeof window === 'undefined' ? undefined : window.sessionStorage,
}) => {
  const stateContext = historyState?.[RETURN_PATH_STATE_KEY];
  const matchingStateContext =
    stateContext?.accountId === String(accountId) &&
    stateContext?.threadId === String(threadId);
  if (matchingStateContext && validReturnPath(stateContext.path, accountId)) {
    return stateContext.path;
  }

  const storedPath = storage?.getItem(
    returnPathStorageKey(accountId, threadId)
  );
  return validReturnPath(storedPath, accountId) ? storedPath : undefined;
};
