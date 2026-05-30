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

const LEGACY_REASONING_FALLBACKS = new Set([
  'Processed by agent',
  'Model returned plain text instead of structured JSON; runtime wrapped it as a Captain response.',
  'Модель вернула текст без структурированного JSON; рантайм сохранил ответ и детали инструментов.',
  'Модель не передала отдельное обоснование. Ответ сохранен, а действия инструментов показаны в деталях.',
]);

const normalizeTraceReasoning = reasoning => {
  const text = String(reasoning || '').trim();
  if (!text) return '';
  return LEGACY_REASONING_FALLBACKS.has(text) ? '' : text;
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

const stepToolName = step =>
  step.toolName || step.tool_name || step.functionName || step.function_name;

const normalizedStepToolName = step => stepToolName(step) || 'tool';

const stepStatus = step => {
  const status = step.status || step.event || 'progress';
  return STATUS_BY_EVENT[status] || status;
};

const stepInput = step =>
  step.input ?? step.inputPreview ?? step.input_preview ?? step.arguments;

const stepOutput = step =>
  step.output ??
  step.outputPreview ??
  step.output_preview ??
  step.result ??
  step.error;

const stepEvent = step => step.event || step.status || 'progress';

const stepToolCallId = step => {
  const explicitId =
    step.toolCallId ||
    step.tool_call_id ||
    step.callId ||
    step.call_id ||
    step.requestId ||
    step.request_id;

  if (explicitId) return explicitId;

  const id = String(step.id || '');
  const parts = id.split(':');
  if (parts.length < 4) return '';

  const [toolName, event, sequence, ...toolCallIdParts] = parts;
  if (toolName !== normalizedStepToolName(step) || event !== stepEvent(step)) {
    return '';
  }
  if (!sequence) return '';

  return toolCallIdParts.join(':');
};

const isTerminalStatus = status => ['finish', 'failed'].includes(status);

const createTraceGroup = (step, index) => ({
  id: step.id || `${normalizedStepToolName(step)}-${index}`,
  message: {
    content: step.content,
    toolName: normalizedStepToolName(step),
    status: stepStatus(step),
  },
});

const mergeStepIntoTraceGroup = (group, step) => {
  const input = formatToolTraceDetail(stepInput(step));
  const output = formatToolTraceDetail(stepOutput(step));

  group.message.content = step.content || group.message.content;
  group.message.status = stepStatus(step);

  if (input && !group.message.input) {
    group.message.input = input;
  }

  if (output) {
    group.message.output = output;
  }

  return group;
};

const buildGroupedToolTraceMessages = toolSteps => {
  const groups = [];
  const groupsByCallId = new Map();
  const activeGroupsByToolName = new Map();

  toolSteps
    .filter(step => step?.content)
    .forEach((step, index) => {
      const toolName = normalizedStepToolName(step);
      const status = stepStatus(step);
      const toolCallId = stepToolCallId(step);
      const callKey = toolCallId ? `${toolName}:${toolCallId}` : '';
      let group;

      if (callKey) {
        group = groupsByCallId.get(callKey);
        if (!group) {
          group = createTraceGroup(step, index);
          groupsByCallId.set(callKey, group);
          groups.push(group);
        }
      } else if (status === 'start') {
        group = createTraceGroup(step, index);
        activeGroupsByToolName.set(toolName, group);
        groups.push(group);
      } else {
        group = activeGroupsByToolName.get(toolName);

        if (!group) {
          group = createTraceGroup(step, index);
          groups.push(group);

          if (status === 'progress') {
            activeGroupsByToolName.set(toolName, group);
          }
        }
      }

      mergeStepIntoTraceGroup(group, step);

      if (isTerminalStatus(status)) {
        if (callKey) {
          groupsByCallId.delete(callKey);
        }

        if (activeGroupsByToolName.get(toolName) === group) {
          activeGroupsByToolName.delete(toolName);
        }
      }
    });

  return groups;
};

const traceReasoning = captainTrace =>
  captainTrace?.reasoning || captainTrace?.reasoning_summary;

const buildReasoningTraceMessage = (captainTrace, options = {}) => {
  const reasoning = normalizeTraceReasoning(traceReasoning(captainTrace));
  if (!reasoning) return null;

  return {
    id: 'captain-reasoning',
    message: {
      content: options.reasoningLabel || 'Reasoning',
      reasoning: String(reasoning),
    },
  };
};

const inferCopilotThinkingStatus = message => {
  if (message.status || message.event) {
    return stepStatus(message);
  }

  const content = message.content || '';
  if (content.startsWith('Completed ')) return 'finish';
  if (content.startsWith('Failed ')) return 'failed';
  if (content.startsWith('Using ')) return 'start';
  return 'progress';
};

const copilotThinkingToolName = message =>
  message.toolName ||
  message.tool_name ||
  message.functionName ||
  message.function_name;

const normalizeGenericCopilotThinkingMessage = copilotMessage => ({
  id: copilotMessage.id,
  message: copilotMessage.message,
});

const normalizeCopilotThinkingStep = copilotMessage => {
  const message = copilotMessage.message || {};
  const toolName = copilotThinkingToolName(message);
  if (!toolName) return null;

  return {
    id: copilotMessage.id,
    content: message.content,
    function_name: toolName,
    status: inferCopilotThinkingStatus(message),
    input: stepInput(message),
    output: stepOutput(message),
    tool_call_id: stepToolCallId(message),
  };
};

export const buildCopilotThinkingTraceMessages = messages => {
  if (!Array.isArray(messages) || messages.length === 0) {
    return [];
  }

  const result = [];
  let toolSteps = [];
  const flushToolSteps = () => {
    if (toolSteps.length === 0) return;

    result.push(...buildGroupedToolTraceMessages(toolSteps));
    toolSteps = [];
  };

  messages.forEach(copilotMessage => {
    const toolStep = normalizeCopilotThinkingStep(copilotMessage);

    if (toolStep) {
      toolSteps.push(toolStep);
      return;
    }

    flushToolSteps();
    result.push(normalizeGenericCopilotThinkingMessage(copilotMessage));
  });

  flushToolSteps();
  return result;
};

export const buildCaptainToolTraceMessages = (
  additionalAttributes,
  options = {}
) => {
  const captainTrace =
    additionalAttributes?.captainTrace || additionalAttributes?.captain_trace;
  const toolSteps = captainTrace?.toolSteps || captainTrace?.tool_steps;
  const reasoningMessage = buildReasoningTraceMessage(captainTrace, options);
  const messages = reasoningMessage ? [reasoningMessage] : [];

  if (Array.isArray(toolSteps) && toolSteps.length > 0) {
    messages.push(...buildGroupedToolTraceMessages(toolSteps));
  }

  return messages;
};
