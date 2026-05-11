import { describe, expect, it } from 'vitest';
import { buildCaptainToolTraceMessages } from './captainToolTrace';

describe('buildCaptainToolTraceMessages', () => {
  it('maps captain trace tool steps to copilot-style messages with canonical status and details', () => {
    expect(
      buildCaptainToolTraceMessages({
        captainTrace: {
          toolSteps: [
            {
              id: 'search:start:1',
              toolName: 'search_documentation',
              event: 'start',
              status: 'start',
              content: 'Using search_documentation',
              input: {
                query: 'pricing',
                apiToken: 'x',
              },
            },
            {
              id: 'search:complete:2',
              toolName: 'search_documentation',
              event: 'complete',
              content: 'Completed search_documentation',
              output: {
                total: 2,
              },
            },
          ],
        },
      })
    ).toEqual([
      {
        id: 'search:start:1',
        message: {
          content: 'Using search_documentation',
          toolName: 'search_documentation',
          status: 'start',
          input: '{\n  "query": "pricing",\n  "apiToken": "[REDACTED]"\n}',
        },
      },
      {
        id: 'search:complete:2',
        message: {
          content: 'Completed search_documentation',
          toolName: 'search_documentation',
          status: 'finish',
          output: '{\n  "total": 2\n}',
        },
      },
    ]);
  });

  it('normalizes legacy status values from stored traces', () => {
    expect(
      buildCaptainToolTraceMessages({
        captainTrace: {
          toolSteps: [
            {
              content: 'Running legacy tool',
              tool_name: 'legacy_tool',
              status: 'running',
            },
            {
              content: 'Completed legacy tool',
              tool_name: 'legacy_tool',
              status: 'completed',
            },
          ],
        },
      }).map(({ message }) => message.status)
    ).toEqual(['progress', 'finish']);
  });

  it('returns an empty array when trace data is missing', () => {
    expect(buildCaptainToolTraceMessages({})).toEqual([]);
    expect(buildCaptainToolTraceMessages(null)).toEqual([]);
  });
});
