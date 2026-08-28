export const resolveBulkSelectionPayload = ({
  appliedFilterPayload = [],
  activeFolderQuery,
}) => {
  if (appliedFilterPayload.length) return appliedFilterPayload;

  return activeFolderQuery?.payload || [];
};
