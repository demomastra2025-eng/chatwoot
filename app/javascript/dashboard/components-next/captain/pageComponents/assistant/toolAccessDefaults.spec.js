import { describe, expect, it } from 'vitest';

import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  buildDefaultToolAccessForUsageMode,
  isToolEnabled,
  normalizeCapabilityToolAccess,
  setToolEnabled,
} from './toolAccessDefaults';

describe('toolAccessDefaults', () => {
  it('preserves multiple enabled capability tools during normalization', () => {
    const normalized = normalizeCapabilityToolAccess(
      {
        agent: {
          enabled: true,
          tool_ids: [
            FAQ_LOOKUP_TOOL_ID,
            HANDOFF_TOOL_ID,
            ADD_CONTACT_NOTE_TOOL_ID,
            ADD_PRIVATE_NOTE_TOOL_ID,
          ],
        },
      },
      'external_agent'
    );

    expect(normalized).toEqual({
      agent: {
        enabled: true,
        tool_ids: [
          FAQ_LOOKUP_TOOL_ID,
          HANDOFF_TOOL_ID,
          ADD_CONTACT_NOTE_TOOL_ID,
          ADD_PRIVATE_NOTE_TOOL_ID,
        ],
      },
    });
  });

  it('keeps existing tools when enabling notes capability step by step', () => {
    let toolAccess = buildDefaultToolAccessForUsageMode('external_agent');

    toolAccess = setToolEnabled(
      toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_CONTACT_NOTE_TOOL_ID,
      true,
      'external_agent'
    );
    toolAccess = setToolEnabled(
      toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_PRIVATE_NOTE_TOOL_ID,
      true,
      'external_agent'
    );

    expect(toolAccess).toEqual({
      agent: {
        enabled: true,
        tool_ids: [
          FAQ_LOOKUP_TOOL_ID,
          HANDOFF_TOOL_ID,
          ADD_CONTACT_NOTE_TOOL_ID,
          ADD_PRIVATE_NOTE_TOOL_ID,
        ],
      },
    });
  });

  it('detects enabled tools from array-based tool_access payloads', () => {
    const toolAccess = {
      agent: {
        enabled: true,
        tool_ids: [FAQ_LOOKUP_TOOL_ID, HANDOFF_TOOL_ID],
      },
    };

    expect(
      isToolEnabled(toolAccess, AGENT_TOOL_SCOPE, FAQ_LOOKUP_TOOL_ID)
    ).toBe(true);
    expect(isToolEnabled(toolAccess, AGENT_TOOL_SCOPE, HANDOFF_TOOL_ID)).toBe(
      true
    );
    expect(
      isToolEnabled(toolAccess, AGENT_TOOL_SCOPE, ADD_CONTACT_NOTE_TOOL_ID)
    ).toBe(false);
  });
});
