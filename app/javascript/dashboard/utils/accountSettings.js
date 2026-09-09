const isDeepEqual = (left, right) => {
  if (Object.is(left, right)) return true;

  if (Array.isArray(left) || Array.isArray(right)) {
    return (
      Array.isArray(left) &&
      Array.isArray(right) &&
      left.length === right.length &&
      left.every((value, index) => isDeepEqual(value, right[index]))
    );
  }

  if (left && right && typeof left === 'object' && typeof right === 'object') {
    const leftKeys = Object.keys(left);
    const rightKeys = Object.keys(right);

    return (
      leftKeys.length === rightKeys.length &&
      leftKeys.every(
        key =>
          Object.prototype.hasOwnProperty.call(right, key) &&
          isDeepEqual(left[key], right[key])
      )
    );
  }

  return false;
};

export const accountSettingsMatch = (account, expectedSettings) =>
  Object.entries(expectedSettings).every(([key, value]) =>
    isDeepEqual(account?.settings?.[key], value)
  );
