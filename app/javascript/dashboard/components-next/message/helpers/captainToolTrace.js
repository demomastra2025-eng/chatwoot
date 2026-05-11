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

const formatDetail = value => {
  if (value === undefined || value === null || value === '') {
    return undefined;
  }

  const normalized = normalizeStructuredValue(value);
  const redacted = redactValue(normalized);

  if (typeof redacted === 'string') {
    return redacted;
  }

  try {
    return JSON.stringify(redacted, null, 2);
  } catch {
    return String(redacted);
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
  const toolSteps = additionalAttributes?.captainTrace?.toolSteps;

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
        input: formatDetail(stepInput(step)),
        output: formatDetail(stepOutput(step)),
      },
    }));
};
