function normalizeAiResponseText(text) {
  const rawText = String(text || '').trim();
  if (!rawText) return null;

  const payload = parseJsonPayload(rawText);
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return { text: rawText, normalized: false };
  }

  const hasCaptainShape = ['response', 'message', 'content', 'answer', 'reasoning', 'artifact_ids', 'handoff_message', 'handoff_reason', 'handoff_status_reason']
    .some(key => Object.prototype.hasOwnProperty.call(payload, key));
  if (!hasCaptainShape) return { text: rawText, normalized: false };

  const response = visibleResponse(payload);
  return compactPayload({
    text: response || 'Понял.',
    normalized: true,
    raw_text: rawText,
    reasoning: normalizeText(payload.reasoning || payload.reasoning_summary),
    artifact_ids: normalizeArray(payload.artifact_ids),
    handoff_message: normalizeText(payload.handoff_message),
    handoff_reason: normalizeText(payload.handoff_reason),
    handoff_status_reason: normalizeText(payload.handoff_status_reason),
    normalized_from: 'captain_json_response'
  });
}

function visibleResponse(payload = {}) {
  const response = normalizeText(payload.response || payload.message || payload.content || payload.answer);
  if (response === 'conversation_handoff') {
    return normalizeText(payload.handoff_message) || 'Сейчас соединю вас со специалистом.';
  }
  return response;
}

function parseJsonPayload(text) {
  const document = extractJsonDocument(stripFencedJson(text));
  if (!document) return null;
  try {
    return JSON.parse(document);
  } catch (_error) {
    return null;
  }
}

function stripFencedJson(text) {
  const match = String(text || '').trim().match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i);
  return match ? match[1].trim() : String(text || '').trim();
}

function extractJsonDocument(text) {
  const source = String(text || '').trim();
  if (source.startsWith('{') && source.endsWith('}')) return source;

  const start = source.indexOf('{');
  if (start < 0) return null;

  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = start; index < source.length; index += 1) {
    const char = source[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === '\\') {
        escaped = true;
      } else if (char === '"') {
        inString = false;
      }
      continue;
    }

    if (char === '"') {
      inString = true;
    } else if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
      if (depth < 0) return null;
    }
  }

  return null;
}

function normalizeText(value) {
  const text = String(value || '').trim();
  return text || undefined;
}

function normalizeArray(value) {
  const items = Array.isArray(value) ? value.map(normalizeText).filter(Boolean) : [];
  return items.length > 0 ? items : undefined;
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { normalizeAiResponseText, parseJsonPayload, extractJsonDocument };
