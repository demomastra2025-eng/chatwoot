const JSON_STRING_WRAPPER_REGEX = /^"(?:.|[\r\n])*"$/;

const parseJsonEncodedString = value => {
  const trimmed = value.trim();
  if (!JSON_STRING_WRAPPER_REGEX.test(trimmed)) return null;

  try {
    const parsed = JSON.parse(trimmed);
    return typeof parsed === 'string' ? parsed : null;
  } catch {
    return null;
  }
};

export const normalizePromptPreviewText = value => {
  if (value == null) return '';

  const rawText = String(value);
  const jsonDecodedText = parseJsonEncodedString(rawText);
  const text = jsonDecodedText ?? rawText;

  return text
    .replace(/\\r\\n/g, '\n')
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\\"/g, '"')
    .replace(/\\\//g, '/');
};
