export const createLatestRequestGuard = () => {
  let currentRequestId = 0;

  return {
    isCurrent: requestId => requestId === currentRequestId,
    start: () => {
      currentRequestId += 1;
      return currentRequestId;
    },
  };
};

export const runLatestRequestRetries = async ({
  attempts,
  isCurrent,
  load,
  shouldRetry,
  wait,
}) => {
  await load();
  if (!isCurrent() || !shouldRetry() || attempts <= 1) return;

  await wait();
  if (!isCurrent()) return;

  await runLatestRequestRetries({
    attempts: attempts - 1,
    isCurrent,
    load,
    shouldRetry,
    wait,
  });
};
