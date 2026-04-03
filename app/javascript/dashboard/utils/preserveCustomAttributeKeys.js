const isPlainObject = value => {
  return Object.prototype.toString.call(value) === '[object Object]';
};

const camelizeKey = key => {
  return key.replace(/[_-]([a-z])/g, (_match, character) =>
    character.toUpperCase()
  );
};

export const preserveCustomAttributeKeys = (source, normalized) => {
  if (Array.isArray(source) && Array.isArray(normalized)) {
    return normalized.map((item, index) =>
      preserveCustomAttributeKeys(source[index], item)
    );
  }

  if (!isPlainObject(source) || !isPlainObject(normalized)) {
    return normalized;
  }

  let sourceCustomAttributes = null;
  if (isPlainObject(source.custom_attributes)) {
    sourceCustomAttributes = source.custom_attributes;
  } else if (isPlainObject(source.customAttributes)) {
    sourceCustomAttributes = source.customAttributes;
  }

  if (sourceCustomAttributes && isPlainObject(normalized.customAttributes)) {
    normalized.customAttributes = sourceCustomAttributes;
  }

  Object.entries(source).forEach(([sourceKey, sourceValue]) => {
    const normalizedKey = camelizeKey(sourceKey);
    const normalizedValue = normalized[normalizedKey];

    if (Array.isArray(sourceValue) && Array.isArray(normalizedValue)) {
      normalized[normalizedKey] = preserveCustomAttributeKeys(
        sourceValue,
        normalizedValue
      );
      return;
    }

    if (isPlainObject(sourceValue) && isPlainObject(normalizedValue)) {
      normalized[normalizedKey] = preserveCustomAttributeKeys(
        sourceValue,
        normalizedValue
      );
    }
  });

  return normalized;
};
