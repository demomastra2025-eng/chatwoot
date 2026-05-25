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
          input: 'Query: pricing\nApi Token: [REDACTED]',
        },
      },
      {
        id: 'search:complete:2',
        message: {
          content: 'Completed search_documentation',
          toolName: 'search_documentation',
          status: 'finish',
          output: 'Total: 2',
        },
      },
    ]);
  });

  it('maps snake_case stored traces from Rails payloads', () => {
    expect(
      buildCaptainToolTraceMessages({
        captain_trace: {
          tool_steps: [
            {
              id: 'tool:finish:1',
              tool_name: 'search_deals',
              status: 'completed',
              content: 'Completed search_deals',
              input_preview: { query: 'VIP' },
              output_preview: { returned_count: 1 },
            },
          ],
        },
      })
    ).toEqual([
      {
        id: 'tool:finish:1',
        message: {
          content: 'Completed search_deals',
          toolName: 'search_deals',
          status: 'finish',
          input: 'Query: VIP',
          output: 'Найдено: 1',
        },
      },
    ]);
  });

  it('normalizes JSON strings inside tool details for readable panels', () => {
    const [{ message }] = buildCaptainToolTraceMessages({
      captainTrace: {
        toolSteps: [
          {
            id: 'crm:finish:1',
            toolName: 'list_deal_custom_fields',
            status: 'finish',
            content: 'Completed list_deal_custom_fields',
            output: {
              message:
                '{\n  "action": "list_deal_custom_fields",\n  "entity_kind": "deal",\n  "returned_count": 2,\n  "fields": [{"key":"source","label":"Источник"}]\n}',
            },
          },
        ],
      },
    });

    expect(message.output).toContain('Сообщение:');
    expect(message.output).toContain('Действие: list_deal_custom_fields');
    expect(message.output).toContain('Найдено: 2');
    expect(message.output).toContain('Поля:');
    expect(message.output).toContain('- Источник');
    expect(message.output).not.toContain('\\n  \\"action\\"');
    expect(message.output).not.toContain('{');
  });

  it('unwraps captain_tool result envelopes and renders them as human-readable lists', () => {
    const [{ message }] = buildCaptainToolTraceMessages({
      captainTrace: {
        toolSteps: [
          {
            id: 'crm:finish:2',
            toolName: 'list_deal_pipelines',
            status: 'finish',
            content: 'Completed list_deal_pipelines',
            output: {
              action: 'captain_tool',
              result: JSON.stringify({
                action: 'list_deal_pipelines',
                filters: { include_inactive: false },
                returned_count: 2,
                pipelines: [
                  { id: 1, name: 'Продажи', active: true },
                  { id: 2, name: 'Поддержка', active: true },
                ],
              }),
            },
          },
        ],
      },
    });

    expect(message.output).toContain('Действие: list_deal_pipelines');
    expect(message.output).toContain('Фильтры:');
    expect(message.output).toContain('Показывать неактивные: Нет');
    expect(message.output).toContain('Найдено: 2');
    expect(message.output).toContain('Воронки:');
    expect(message.output).toContain('- Продажи #1');
    expect(message.output).not.toContain('captain_tool');
    expect(message.output).not.toContain('"result"');
    expect(message.output).not.toContain('\\"action\\"');
  });

  it('keeps malformed JSON-like strings readable as plain strings', () => {
    const [{ message }] = buildCaptainToolTraceMessages({
      captainTrace: {
        toolSteps: [
          {
            content: 'Failed malformed payload tool',
            output: {
              message: '{not valid json',
              apiToken: 'x',
            },
          },
        ],
      },
    });

    expect(message.output).toContain('Сообщение: {not valid json');
    expect(message.output).toContain('Api Token: [REDACTED]');
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
