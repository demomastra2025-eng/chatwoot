import { describe, expect, it } from 'vitest';
import { buildCaptainToolTraceMessages } from './captainToolTrace';

describe('buildCaptainToolTraceMessages', () => {
  it('maps captain trace tool steps to copilot-style messages', () => {
    expect(
      buildCaptainToolTraceMessages({
        captainTrace: {
          toolSteps: [
            {
              id: 'search:start:1',
              toolName: 'search_documentation',
              event: 'start',
              content: 'Using search_documentation',
            },
            {
              id: 'search:complete:2',
              toolName: 'search_documentation',
              event: 'complete',
              content: 'Completed search_documentation',
            },
          ],
        },
      })
    ).toEqual([
      {
        id: 'search:start:1',
        message: {
          content: 'Using search_documentation',
        },
      },
      {
        id: 'search:complete:2',
        message: {
          content: 'Completed search_documentation',
        },
      },
    ]);
  });

  it('returns an empty array when trace data is missing', () => {
    expect(buildCaptainToolTraceMessages({})).toEqual([]);
    expect(buildCaptainToolTraceMessages(null)).toEqual([]);
  });
});
