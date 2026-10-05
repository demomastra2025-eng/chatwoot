import { describe, expect, it } from 'vitest';

import { MESSAGE_TYPES } from './constants';
import {
  isCaptainToolActivityMessage,
  isUsefulTimelineMessage,
} from './timelineMessageVisibility';

const toolLine = overrides => ({
  messageType: MESSAGE_TYPES.ACTIVITY,
  sourceId: 'captain-tool:5f2c',
  content: 'ИИ Агент выполнил инструмент «search_scheduling_services»',
  contentAttributes: {
    data: {
      type: 'captain_tool_event',
      event: 'completed',
      toolName: 'search_scheduling_services',
    },
  },
  ...overrides,
});

describe('isCaptainToolActivityMessage', () => {
  it('recognises the projector data type on a camelCased message', () => {
    expect(isCaptainToolActivityMessage(toolLine())).toBe(true);
  });

  it('recognises a raw snake_case websocket payload', () => {
    expect(
      isCaptainToolActivityMessage({
        message_type: 2,
        source_id: 'captain-tool:5f2c',
        content_attributes: { data: { type: 'captain_tool_event' } },
      })
    ).toBe(true);
  });

  it('recognises a stored row that only has the source namespace', () => {
    expect(
      isCaptainToolActivityMessage(
        toolLine({ contentAttributes: {}, sourceId: 'captain-tool:legacy' })
      )
    ).toBe(true);
  });

  it('recognises a stored row that only has the data type', () => {
    expect(isCaptainToolActivityMessage(toolLine({ sourceId: null }))).toBe(
      true
    );
  });

  it('never decides by the visible text', () => {
    expect(
      isCaptainToolActivityMessage(
        toolLine({ sourceId: undefined, contentAttributes: {} })
      )
    ).toBe(false);
    expect(
      isCaptainToolActivityMessage(
        toolLine({
          messageType: MESSAGE_TYPES.INCOMING,
          sourceId: undefined,
          contentAttributes: {},
        })
      )
    ).toBe(false);
  });

  it('only looks at activity messages', () => {
    expect(
      isCaptainToolActivityMessage(
        toolLine({ messageType: MESSAGE_TYPES.OUTGOING })
      )
    ).toBe(false);
  });

  it('is safe for empty input', () => {
    expect(isCaptainToolActivityMessage(undefined)).toBe(false);
    expect(isCaptainToolActivityMessage({})).toBe(false);
  });
});

describe('isUsefulTimelineMessage', () => {
  it('hides Captain tool lines', () => {
    expect(isUsefulTimelineMessage(toolLine())).toBe(false);
    expect(
      isUsefulTimelineMessage(
        toolLine({
          contentAttributes: {
            data: { type: 'captain_tool_event', event: 'failed' },
          },
        })
      )
    ).toBe(false);
  });

  it('keeps other activity such as the handoff to a human', () => {
    expect(
      isUsefulTimelineMessage({
        messageType: MESSAGE_TYPES.ACTIVITY,
        content: 'Conversation was marked open by AI Agent',
        contentAttributes: {},
      })
    ).toBe(true);
  });

  it('keeps regular messages with the same text', () => {
    expect(
      isUsefulTimelineMessage({
        messageType: MESSAGE_TYPES.INCOMING,
        content: toolLine().content,
      })
    ).toBe(true);
  });

  it('still hides the existing noisy telemetry', () => {
    expect(
      isUsefulTimelineMessage({
        messageType: MESSAGE_TYPES.ACTIVITY,
        sourceId: 'ai_voice_event:call:ai_speaking:1',
        contentAttributes: {},
      })
    ).toBe(false);
  });
});
