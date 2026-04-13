const CODE_BLOCK_PATTERN = /```[\s\S]*?```/g;
const FIELD_REFERENCE_PATTERN = /\(field:\/\/[^)]+\)/;
const INLINE_CODE_PATTERN = /`[^`]*`/g;
const LIQUID_OUTPUT_PATTERN = /{{[\s\S]+?}}/;
const LIQUID_TAG_PATTERN = /{%[\s\S]+?%}/;

const stripCode = content => {
  return String(content || '')
    .replace(CODE_BLOCK_PATTERN, ' ')
    .replace(INLINE_CODE_PATTERN, ' ');
};

export const hasTouchTemplateSyntax = content => {
  const normalizedContent = stripCode(content);

  if (!normalizedContent.trim()) {
    return false;
  }

  return (
    LIQUID_OUTPUT_PATTERN.test(normalizedContent) ||
    LIQUID_TAG_PATTERN.test(normalizedContent) ||
    FIELD_REFERENCE_PATTERN.test(normalizedContent)
  );
};

export const detectTouchTextMode = ({
  actionType = 'send_message',
  body = '',
  instructions = '',
  useAiAuthoring = false,
  textMode = '',
} = {}) => {
  if (actionType !== 'send_message') {
    return 'static';
  }

  if (useAiAuthoring || textMode === 'agent') {
    return 'agent';
  }

  const trimmedBody = String(body || '').trim();
  if (!trimmedBody && String(instructions || '').trim()) {
    return 'agent';
  }

  return hasTouchTemplateSyntax(trimmedBody) ? 'dynamic' : 'static';
};
