import { describe, expect, it } from 'vitest';

import {
  ADD_CONTACT_NOTE_TOOL_ID,
  ADD_PRIVATE_NOTE_TOOL_ID,
  AGENT_TOOL_SCOPE,
  FAQ_LOOKUP_TOOL_ID,
  HANDOFF_TOOL_ID,
  SERVICE_SEARCH_TOOL_ID,
  buildDefaultAgentToolAccess,
  isSharedReadToolOn,
  isToolEnabled,
  normalizeCapabilityToolAccess,
  setSharedReadToolOn,
  setToolEnabled,
} from './toolAccessDefaults';

describe('toolAccessDefaults', () => {
  it('preserves multiple enabled capability tools during normalization', () => {
    const normalized = normalizeCapabilityToolAccess({
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
    let toolAccess = buildDefaultAgentToolAccess();

    toolAccess = setToolEnabled(
      toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_CONTACT_NOTE_TOOL_ID,
      true
    );
    toolAccess = setToolEnabled(
      toolAccess,
      AGENT_TOOL_SCOPE,
      ADD_PRIVATE_NOTE_TOOL_ID,
      true
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

  it('keeps an explicit empty scope when disabling all default tools', () => {
    let toolAccess = buildDefaultAgentToolAccess();

    toolAccess = setToolEnabled(
      toolAccess,
      AGENT_TOOL_SCOPE,
      FAQ_LOOKUP_TOOL_ID,
      false
    );
    toolAccess = setToolEnabled(
      toolAccess,
      AGENT_TOOL_SCOPE,
      HANDOFF_TOOL_ID,
      false
    );

    expect(toolAccess).toEqual({
      agent: {
        enabled: true,
        tool_ids: [],
      },
    });
  });

  it('preserves unrelated selected tools and scopes when toggling capability tools', () => {
    const toolAccess = setToolEnabled(
      {
        agent: {
          enabled: true,
          tool_ids: [FAQ_LOOKUP_TOOL_ID, 'create_deal'],
        },
        assistant: {
          enabled: true,
          tool_ids: ['mcp__github__list_issues'],
        },
      },
      AGENT_TOOL_SCOPE,
      HANDOFF_TOOL_ID,
      true
    );

    expect(toolAccess).toEqual({
      agent: {
        enabled: true,
        tool_ids: [FAQ_LOOKUP_TOOL_ID, 'create_deal', HANDOFF_TOOL_ID],
      },
      assistant: {
        enabled: true,
        tool_ids: ['mcp__github__list_issues'],
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

describe('shared read tools (FAQ lookup and service search)', () => {
  it('are on until the agent lists them as switched off', () => {
    expect(isSharedReadToolOn({}, FAQ_LOOKUP_TOOL_ID)).toBe(true);
    expect(isSharedReadToolOn(undefined, SERVICE_SEARCH_TOOL_ID)).toBe(true);
    const access = {
      agent: { enabled: true, disabled_tool_ids: [SERVICE_SEARCH_TOOL_ID] },
    };
    expect(isSharedReadToolOn(access, SERVICE_SEARCH_TOOL_ID)).toBe(false);
    expect(isSharedReadToolOn(access, FAQ_LOOKUP_TOOL_ID)).toBe(true);
  });

  it('are switched off and on again without touching the rest of the access', () => {
    const access = {
      agent: { enabled: true, tool_ids: [HANDOFF_TOOL_ID] },
      assistant: { enabled: true, tool_ids: ['x'] },
    };
    const off = setSharedReadToolOn(access, FAQ_LOOKUP_TOOL_ID, false);
    expect(off.agent).toEqual({
      enabled: true,
      tool_ids: [HANDOFF_TOOL_ID],
      disabled_tool_ids: [FAQ_LOOKUP_TOOL_ID],
    });
    expect(off.assistant).toEqual(access.assistant);
    expect(access.agent.disabled_tool_ids).toBeUndefined();

    const on = setSharedReadToolOn(off, FAQ_LOOKUP_TOOL_ID, true);
    expect(on.agent).toEqual({ enabled: true, tool_ids: [HANDOFF_TOOL_ID] });
  });

  it('start from the default agent access when the agent has none, and ignore other tools', () => {
    const off = setSharedReadToolOn({}, SERVICE_SEARCH_TOOL_ID, false);
    expect(off.agent).toEqual({
      enabled: true,
      tool_ids: [FAQ_LOOKUP_TOOL_ID, HANDOFF_TOOL_ID],
      disabled_tool_ids: [SERVICE_SEARCH_TOOL_ID],
    });
    expect(setSharedReadToolOn({}, 'web_search', false)).toEqual({});
  });
});
