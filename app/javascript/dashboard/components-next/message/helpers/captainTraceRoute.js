const firstPresent = values =>
  values.find(value => value !== undefined && value !== null && value !== '');

export const buildCaptainTraceQuery = (
  additionalAttributes = {},
  routeParams = {}
) => {
  const captainTrace =
    additionalAttributes?.captainTrace ||
    additionalAttributes?.captain_trace ||
    {};
  const params = routeParams || {};
  const hasTraceContext = Boolean(
    Object.keys(captainTrace).length ||
      firstPresent([
        additionalAttributes?.traceId,
        additionalAttributes?.trace_id,
        additionalAttributes?.sessionId,
        additionalAttributes?.session_id,
        additionalAttributes?.conversationDisplayId,
        additionalAttributes?.conversation_display_id,
        additionalAttributes?.copilotThreadId,
        additionalAttributes?.copilot_thread_id,
      ])
  );

  if (!hasTraceContext) return null;

  const traceId = firstPresent([
    captainTrace?.traceId,
    captainTrace?.trace_id,
    additionalAttributes?.traceId,
    additionalAttributes?.trace_id,
  ]);
  const sessionId = firstPresent([
    captainTrace?.sessionId,
    captainTrace?.session_id,
    additionalAttributes?.sessionId,
    additionalAttributes?.session_id,
  ]);
  const conversationDisplayId = firstPresent([
    captainTrace?.conversationDisplayId,
    captainTrace?.conversation_display_id,
    additionalAttributes?.conversationDisplayId,
    additionalAttributes?.conversation_display_id,
    params.conversation_id,
    params.conversationId,
  ]);
  const copilotThreadId = firstPresent([
    captainTrace?.copilotThreadId,
    captainTrace?.copilot_thread_id,
    additionalAttributes?.copilotThreadId,
    additionalAttributes?.copilot_thread_id,
  ]);

  const query = {
    tab: 'traces',
    ...(traceId ? { trace_id: traceId } : {}),
    ...(sessionId ? { session_id: sessionId } : {}),
    ...(conversationDisplayId
      ? { conversation_display_id: conversationDisplayId }
      : {}),
    ...(copilotThreadId ? { copilot_thread_id: copilotThreadId } : {}),
  };

  return Object.keys(query).length > 1 ? query : null;
};
