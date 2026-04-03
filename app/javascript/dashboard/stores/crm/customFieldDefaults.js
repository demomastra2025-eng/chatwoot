const isPlainObject = value =>
  Object.prototype.toString.call(value) === '[object Object]';

export const cloneCustomFieldDefaultValue = value => {
  if (Array.isArray(value)) {
    return value.map(item => cloneCustomFieldDefaultValue(item));
  }

  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        cloneCustomFieldDefaultValue(item),
      ])
    );
  }

  return value;
};

export const buildDefaultCustomAttributes = definitions => {
  return definitions.reduce((result, definition) => {
    if (
      definition.defaultValue !== null &&
      definition.defaultValue !== undefined
    ) {
      result[definition.key] = cloneCustomFieldDefaultValue(
        definition.defaultValue
      );
    }

    return result;
  }, {});
};

export const mergeMissingDefaultCustomAttributes = (
  customAttributes = {},
  definitions = []
) => {
  const nextAttributes = { ...(customAttributes || {}) };

  definitions.forEach(definition => {
    if (
      Object.prototype.hasOwnProperty.call(nextAttributes, definition.key) ||
      definition.defaultValue === null ||
      definition.defaultValue === undefined
    ) {
      return;
    }

    nextAttributes[definition.key] = cloneCustomFieldDefaultValue(
      definition.defaultValue
    );
  });

  return nextAttributes;
};
