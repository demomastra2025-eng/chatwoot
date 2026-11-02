const canonical = value => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map(key => [key, canonical(value[key])])
    );
  }
  return value;
};

// An older server can return HTTP 200 after ignoring unknown settings. Confirm
// the postcondition before telling the user the change was saved.
export const accountSettingsMatch = (account, expected) =>
  Object.keys(expected).every(
    key =>
      JSON.stringify(canonical(account?.settings?.[key])) ===
      JSON.stringify(canonical(expected[key]))
  );

export const accountSettingsFingerprint = (account, keys) =>
  JSON.stringify(
    canonical([
      account?.id,
      Object.fromEntries(keys.map(key => [key, account?.settings?.[key]])),
    ])
  );
