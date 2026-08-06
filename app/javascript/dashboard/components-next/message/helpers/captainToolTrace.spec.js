import { describe, expect, it } from 'vitest';
import {
  buildCaptainToolTraceMessages,
  buildCopilotThinkingTraceMessages,
} from './captainToolTrace';

describe('buildCaptainToolTraceMessages', () => {
  it('combines start and complete steps into one copilot-style tool message', () => {
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
          content: 'Completed search_documentation',
          toolName: 'search_documentation',
          status: 'finish',
          input: 'Query: pricing\nApi Token: [REDACTED]',
          output: 'Total: 2',
        },
      },
    ]);
  });

  it('keeps repeated calls to the same tool separate when a call id is present', () => {
    expect(
      buildCaptainToolTraceMessages({
        captainTrace: {
          toolSteps: [
            {
              id: 'faq_lookup:start:1:call-a',
              toolName: 'faq_lookup',
              event: 'start',
              content: 'Using faq_lookup',
              input: { query: 'price' },
            },
            {
              id: 'faq_lookup:finish:2:call-a',
              toolName: 'faq_lookup',
              event: 'finish',
              content: 'Completed faq_lookup',
              output: { answer: '1000' },
            },
            {
              id: 'faq_lookup:start:3:call-b',
              toolName: 'faq_lookup',
              event: 'start',
              content: 'Using faq_lookup',
              input: { query: 'address' },
            },
            {
              id: 'faq_lookup:finish:4:call-b',
              toolName: 'faq_lookup',
              event: 'finish',
              content: 'Completed faq_lookup',
              output: { answer: 'Main street' },
            },
          ],
        },
      }).map(({ message }) => ({
        status: message.status,
        input: message.input,
        output: message.output,
      }))
    ).toEqual([
      {
        status: 'finish',
        input: 'Query: price',
        output: 'Answer: 1000',
      },
      {
        status: 'finish',
        input: 'Query: address',
        output: 'Answer: Main street',
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

  it('uses canonical grouped tool calls when present and avoids duplicate step rendering', () => {
    expect(
      buildCaptainToolTraceMessages({
        captain_trace: {
          tool_calls: [
            {
              tool_call_id: 'call-1',
              tool_name: 'update_deal',
              status: 'completed',
              input: { title: 'Хлопок', access_token: 'secret' },
              output: { amount: 180000 },
            },
          ],
          tool_steps: [
            {
              id: 'update_deal:start:1:call-1',
              tool_name: 'update_deal',
              status: 'start',
              content: 'Using update_deal',
            },
            {
              id: 'update_deal:complete:2:call-1',
              tool_name: 'update_deal',
              status: 'complete',
              content: 'Completed update_deal',
            },
          ],
        },
      })
    ).toEqual([
      {
        id: 'call-1',
        message: {
          content: 'Completed update_deal',
          toolName: 'update_deal',
          status: 'finish',
          input: 'Название: Хлопок\nAccess token: [REDACTED]',
          output: 'Amount: 180000',
        },
      },
    ]);
  });

  it('keeps root search name arguments visible in details', () => {
    const [message] = buildCaptainToolTraceMessages({
      captain_trace: {
        tool_calls: [
          {
            tool_call_id: 'search-contact-1',
            tool_name: 'search_contacts',
            status: 'completed',
            input: { name: 'Аружан' },
            output: { returned_count: 1 },
          },
        ],
      },
    });

    expect(message.message.input).toBe('Название: Аружан');
  });

  it('renders partial canonical tool calls as a running grouped tool message', () => {
    expect(
      buildCaptainToolTraceMessages({
        captain_trace: {
          tool_calls: [
            {
              tool_call_id: 'call-running',
              tool_name: 'search_deals',
              status: 'partial',
              input: { query: 'Хлопок' },
            },
          ],
        },
      })
    ).toEqual([
      {
        id: 'call-running',
        message: {
          content: 'Running search_deals',
          toolName: 'search_deals',
          status: 'progress',
          input: 'Query: Хлопок',
        },
      },
    ]);
  });

  it('adds response reasoning before tool steps', () => {
    expect(
      buildCaptainToolTraceMessages(
        {
          captain_trace: {
            reasoning: 'Найдена сделка по ID и обновлена сумма.',
            tool_steps: [
              {
                id: 'tool:finish:1',
                tool_name: 'update_deal',
                status: 'completed',
                content: 'Completed update_deal',
                output_preview: { deal_id: 52 },
              },
            ],
          },
        },
        { reasoningLabel: 'Мысли' }
      ).map(({ message }) => ({
        content: message.content,
        reasoning: message.reasoning,
        toolName: message.toolName,
      }))
    ).toEqual([
      {
        content: 'Мысли',
        reasoning: 'Найдена сделка по ID и обновлена сумма.',
        toolName: undefined,
      },
      {
        content: 'Completed update_deal',
        reasoning: undefined,
        toolName: 'update_deal',
      },
    ]);
  });

  it('returns a reasoning-only trace when no tool steps are present', () => {
    expect(
      buildCaptainToolTraceMessages(
        {
          captain_trace: {
            reasoning: 'Ответ подготовлен без вызова инструментов.',
          },
        },
        { reasoningLabel: 'Мысли' }
      )
    ).toEqual([
      {
        id: 'captain-reasoning',
        message: {
          content: 'Мысли',
          reasoning: 'Ответ подготовлен без вызова инструментов.',
        },
      },
    ]);
  });

  it('prefers native model reasoning and does not render structured or system fallback text as reasoning', () => {
    expect(
      buildCaptainToolTraceMessages(
        {
          captain_trace: {
            native_reasoning: {
              text: 'Нативное рассуждение модели.',
              source: 'openrouter',
            },
            structured_reasoning: 'Схемное объяснение Captain.',
            system_fallback_reason: 'Детерминированный fallback.',
          },
        },
        { reasoningLabel: 'Рассуждение модели' }
      )
    ).toEqual([
      {
        id: 'captain-reasoning',
        message: {
          content: 'Рассуждение модели',
          reasoning: 'Нативное рассуждение модели.',
        },
      },
    ]);

    expect(
      buildCaptainToolTraceMessages({
        captain_trace: {
          structured_reasoning: 'Схемное объяснение Captain.',
          system_fallback_reason: 'Детерминированный fallback.',
        },
      })
    ).toEqual([]);
  });

  it('shows OpenRouter redacted native reasoning marker without inventing text', () => {
    expect(
      buildCaptainToolTraceMessages(
        {
          captain_trace: {
            native_reasoning: {
              encrypted: true,
              source: 'openrouter',
            },
          },
        },
        { reasoningLabel: 'Рассуждение модели' }
      )
    ).toEqual([
      {
        id: 'captain-reasoning',
        message: {
          content: 'Рассуждение модели',
          reasoning: 'Модель скрыла рассуждение',
        },
      },
    ]);
  });

  it('hides legacy technical fallback reasoning', () => {
    expect(
      buildCaptainToolTraceMessages({
        captain_trace: {
          reasoning:
            'Model returned plain text instead of structured JSON; runtime wrapped it as a Captain response.',
        },
      })
    ).toEqual([]);
  });

  it('hides old backend generated string-response reasoning', () => {
    expect(
      buildCaptainToolTraceMessages({
        captain_trace: {
          reasoning: 'Processed by agent',
        },
      })
    ).toEqual([]);
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

  it('renders retrieval trace and chunk metadata with user-readable labels', () => {
    const [{ message }] = buildCaptainToolTraceMessages({
      captainTrace: {
        toolSteps: [
          {
            id: 'rag:finish:1',
            toolName: 'knowledge_search',
            status: 'finish',
            content: 'Completed knowledge_search',
            output: {
              retrieval_trace: {
                retrieval_mode: 'semantic_chunk',
                document_name: 'Прайс-лист',
                document_chunk_id: 32,
                content_preview: 'Стоимость доставки от 1000 KZT',
                score: 0.92,
              },
            },
          },
        ],
      },
    });

    expect(message.output).toContain('Источники ответа:');
    expect(message.output).toContain('Режим поиска: semantic_chunk');
    expect(message.output).toContain('Документ: Прайс-лист');
    expect(message.output).toContain('Фрагмент: 32');
    expect(message.output).toContain('Оценка релевантности: 0.92');
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

  it('normalizes and combines legacy status values from stored traces', () => {
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
    ).toEqual(['finish']);
  });

  it('returns an empty array when trace data is missing', () => {
    expect(buildCaptainToolTraceMessages({})).toEqual([]);
    expect(buildCaptainToolTraceMessages(null)).toEqual([]);
  });
});

describe('buildCopilotThinkingTraceMessages', () => {
  it('combines live copilot thinking tool start and finish messages', () => {
    expect(
      buildCopilotThinkingTraceMessages([
        {
          id: 1,
          message: {
            content: 'Using search_deals',
            function_name: 'search_deals',
            tool_call_id: 'call-1',
            status: 'start',
            input: { query: 'VIP' },
          },
        },
        {
          id: 2,
          message: {
            content: 'Completed search_deals',
            function_name: 'search_deals',
            tool_call_id: 'call-1',
            status: 'finish',
            output: { returned_count: 1 },
          },
        },
      ])
    ).toEqual([
      {
        id: 1,
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

  it('keeps non-tool thinking messages in order around grouped tool calls', () => {
    expect(
      buildCopilotThinkingTraceMessages([
        {
          id: 1,
          message: {
            content: 'Planning answer',
            reasoning: 'Reading context',
          },
        },
        {
          id: 2,
          message: {
            content: 'Using search_deals',
            function_name: 'search_deals',
          },
        },
        {
          id: 3,
          message: {
            content: 'Completed search_deals',
            function_name: 'search_deals',
          },
        },
      ]).map(({ message }) => message.content)
    ).toEqual(['Planning answer', 'Completed search_deals']);
  });
});
