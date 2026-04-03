export const FIELD_REFERENCE_GLOBAL_REGEX =
  /\[([^\]]+)\]\(field:\/\/([^)]+)\)/g;
export const FIELD_REFERENCE_EXACT_REGEX =
  /^\s*\[([^\]]+)\]\(field:\/\/([^)]+)\)\s*$/;

export const buildTemplateFieldReference = field => {
  return `[${field.title}](field://${field.id})`;
};

export const extractSingleTemplateFieldReference = value => {
  if (typeof value !== 'string') return null;

  const match = value.match(FIELD_REFERENCE_EXACT_REGEX);
  if (!match) return null;

  return {
    label: match[1],
    fieldId: match[2],
  };
};

export const renderTemplateFieldReferencePreview = value => {
  if (typeof value !== 'string') return value;

  return value.replace(FIELD_REFERENCE_GLOBAL_REGEX, (_, label) => label);
};
