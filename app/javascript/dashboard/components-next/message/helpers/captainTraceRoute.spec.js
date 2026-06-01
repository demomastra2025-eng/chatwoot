import { describe, expect, it } from 'vitest';

import { buildCaptainTraceQuery } from './captainTraceRoute';

describe('buildCaptainTraceQuery', () => {
  it('builds an observability trace query from snake_case Captain trace attributes', () => {
    expect(
      buildCaptainTraceQuery(
        {
          captain_trace: {
            trace_id: 'trace-1',
            session_id: 'session-1',
            copilot_thread_id: 'thread-1',
          },
        },
        { conversation_id: '5' }
      )
    ).toEqual({
      tab: 'traces',
      trace_id: 'trace-1',
      session_id: 'session-1',
      conversation_display_id: '5',
      copilot_thread_id: 'thread-1',
    });
  });

  it('does not expose a logs action without trace context', () => {
    expect(buildCaptainTraceQuery({}, { conversation_id: '5' })).toBe(null);
  });
});
