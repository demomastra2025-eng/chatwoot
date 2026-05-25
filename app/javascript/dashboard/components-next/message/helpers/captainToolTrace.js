const SENSITIVE_KEY_PATTERN =
  /token|secret|password|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|credential|cookie|phone|телефон/i;

const STATUS_BY_EVENT = {
  start: 'start',
  progress: 'progress',
  running: 'progress',
  finish: 'finish',
  complete: 'finish',
  completed: 'finish',
  success: 'finish',
  failed: 'failed',
  error: 'failed',
};

const HUMAN_KEY_LABELS = {
  action: 'Действие',
  result: 'Результат',
  status: 'Статус',
  message: 'Сообщение',
  error: 'Ошибка',
  filters: 'Фильтры',
  returned_count: 'Найдено',
  pipelines: 'Воронки',
  pipeline: 'Воронка',
  stages: 'Этапы',
  fields: 'Поля',
  deals: 'Сделки',
  deal: 'Сделка',
  tasks: 'Задачи',
  contacts: 'Контакты',
  id: 'ID',
  name: 'Название',
  title: 'Название',
  label: 'Метка',
  key: 'Ключ',
  description: 'Описание',
  active: 'Активна',
  include_inactive: 'Показывать неактивные',
  returnedCount: 'Найдено',
  tool_name: 'Инструмент',
  toolName: 'Инструмент',
};

const parseStructuredString = value => {
  if (typeof value !== 'string') return value;

  const trimmed = value.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return value;

  try {
    return JSON.parse(trimmed);
  } catch {
    return value;
  }
};

const normalizeStructuredValue = value => {
  const parsedValue = parseStructuredString(value);

  if (Array.isArray(parsedValue)) {
    return parsedValue.map(item => normalizeStructuredValue(item));
  }

  if (parsedValue && typeof parsedValue === 'object') {
    return Object.entries(parsedValue).reduce((acc, [key, childValue]) => {
      acc[key] = normalizeStructuredValue(childValue);
      return acc;
    }, {});
  }

  return parsedValue;
};

const redactValue = value => {
  if (Array.isArray(value)) {
    return value.map(item => redactValue(item));
  }

  if (value && typeof value === 'object') {
    return Object.entries(value).reduce((acc, [key, childValue]) => {
      acc[key] = SENSITIVE_KEY_PATTERN.test(key)
        ? '[REDACTED]'
        : redactValue(childValue);
      return acc;
    }, {});
  }

  if (typeof value === 'string') {
    return value
      .replace(/Bearer\s+[A-Za-z0-9._-]+/g, 'Bearer [REDACTED]')
      .replace(
        /(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=([^\s&]+)/gi,
        '$1=[REDACTED]'
      );
  }

  return value;
};

const humanizeKey = key => {
  if (HUMAN_KEY_LABELS[key]) return HUMAN_KEY_LABELS[key];

  return key
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .replace(/^\w/, firstChar => firstChar.toUpperCase());
};

const humanizePrimitive = value => {
  if (value === true) return 'Да';
  if (value === false) return 'Нет';
  if (value === null || value === undefined || value === '') return '—';
  return String(value);
};

const unwrapCaptainToolEnvelope = value => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return value;

  const keys = Object.keys(value);
  const hasCaptainToolAction = value.action === 'captain_tool';
  const hasStructuredResult =
    value.result &&
    typeof value.result === 'object' &&
    !Array.isArray(value.result);

  if (hasCaptainToolAction && hasStructuredResult) {
    return value.result;
  }

  if (keys.length === 1 && hasStructuredResult) {
    return value.result;
  }

  return value;
};

const compactObjectTitle = value => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return '';

  const primary = value.name || value.title || value.label || value.key;
  const idSuffix = value.id === undefined ? '' : ` #${value.id}`;

  if (primary) return `${primary}${idSuffix}`;
  if (value.action) return humanizePrimitive(value.action);
  if (value.status) return humanizePrimitive(value.status);
  return '';
};

const shouldSkipNestedSummaryKey = (key, parentValue) =>
  Boolean(
    parentValue &&
      typeof parentValue === 'object' &&
      !Array.isArray(parentValue) &&
      ['name', 'title', 'label'].includes(key) &&
      compactObjectTitle(parentValue)
  );

function formatReadableValue(value, level = 0) {
  const indent = `${'  '.repeat(level)}`;

  const formatObjectValue = objectValue =>
    Object.entries(objectValue)
      .filter(([, childValue]) => childValue !== undefined && childValue !== '')
      .filter(([key]) => !shouldSkipNestedSummaryKey(key, objectValue))
      .map(([key, childValue]) => {
        const label = humanizeKey(key);
        const formattedValue = formatReadableValue(childValue, level + 1);

        if (
          Array.isArray(childValue) ||
          (childValue && typeof childValue === 'object')
        ) {
          return `${indent}${label}:\n${formattedValue}`;
        }

        return `${indent}${label}: ${formattedValue}`;
      })
      .join('\n');

  const formatArrayItemValue = (item, index) => {
    const prefix = `${indent}- `;

    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      return `${prefix}${formatReadableValue(item, level + 1)}`;
    }

    const title = compactObjectTitle(item) || `#${index + 1}`;
    const nested = formatReadableValue(item, level + 1);

    if (!nested) return `${prefix}${title}`;
    return `${prefix}${title}\n${nested}`;
  };

  const unwrapped = unwrapCaptainToolEnvelope(value);

  if (Array.isArray(unwrapped)) {
    if (unwrapped.length === 0) return `${indent}—`;
    return unwrapped.map(formatArrayItemValue).join('\n');
  }

  if (unwrapped && typeof unwrapped === 'object') {
    const formatted = formatObjectValue(unwrapped);
    return formatted || `${indent}—`;
  }

  return humanizePrimitive(unwrapped);
}

export const formatToolTraceDetail = value => {
  if (value === undefined || value === null || value === '') {
    return undefined;
  }

  const normalized = normalizeStructuredValue(value);
  const redacted = redactValue(normalized);

  try {
    return formatReadableValue(redacted);
  } catch {
    if (typeof redacted === 'string') return redacted;

    try {
      return JSON.stringify(redacted, null, 2);
    } catch {
      return String(redacted);
    }
  }
};

const stepToolName = step => step.toolName || step.tool_name || 'tool';

const stepStatus = step => {
  const status = step.status || step.event || 'progress';
  return STATUS_BY_EVENT[status] || status;
};

const stepInput = step =>
  step.input ?? step.inputPreview ?? step.input_preview ?? step.arguments;

const stepOutput = step =>
  step.output ?? step.outputPreview ?? step.output_preview ?? step.result;

export const buildCaptainToolTraceMessages = additionalAttributes => {
  const captainTrace =
    additionalAttributes?.captainTrace || additionalAttributes?.captain_trace;
  const toolSteps = captainTrace?.toolSteps || captainTrace?.tool_steps;

  if (!Array.isArray(toolSteps) || toolSteps.length === 0) {
    return [];
  }

  return toolSteps
    .filter(step => step?.content)
    .map((step, index) => ({
      id: step.id || `${stepToolName(step)}-${index}`,
      message: {
        content: step.content,
        toolName: stepToolName(step),
        status: stepStatus(step),
        input: formatToolTraceDetail(stepInput(step)),
        output: formatToolTraceDetail(stepOutput(step)),
      },
    }));
};
