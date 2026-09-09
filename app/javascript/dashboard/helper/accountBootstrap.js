export const ensureAccountLoaded = async ({
  accountId,
  getAccount,
  loadAccounts,
}) => {
  if (getAccount(accountId)?.id) return false;

  await loadAccounts();
  return true;
};
