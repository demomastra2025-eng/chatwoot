import { describe, expect, it } from 'vitest';
import {
  AGENT_DESCRIPTION_MAX_LENGTH,
  agentInstructionMaxLength,
  buildAgentDraft,
  buildAgentUpdatePayload,
  findAgentModelMetadata,
  isAgentDraftDirty,
  rebaseAgentDraft,
  validateAgentDraft,
} from './agentDraft';

const assistant = {
  name: 'Agent',
  routing_description: 'Helps customers',
  description: 'Be helpful.',
  config: {
    model: 'legacy',
    temperature: 0.9,
    thinking_effort: 'high',
    feature_memory: true,
  },
};
const platform = { canEditPrompts: true };
const capabilities = {
  version: 1,
  scopes: {
    agent: { enabled: true, tool_ids: [] },
    assistant: { enabled: false, tool_ids: [] },
  },
};

describe('platform managed agent drafts', () => {
  it('does not copy retired model or workspace settings into an editable draft', () => {
    expect(buildAgentDraft(assistant)).toEqual({
      name: 'Agent',
      routingDescription: 'Helps customers',
      instruction: 'Be helpful.',
    });
  });

  it('keeps a redacted instruction absent instead of synthesizing an empty instruction', () => {
    const { description, ...redacted } = assistant;
    const base = buildAgentDraft(redacted);
    expect(base).not.toHaveProperty('instruction');
    const renamed = { ...base, name: 'Renamed' };
    expect(validateAgentDraft(renamed, base).valid).toBe(true);
    expect(validateAgentDraft(renamed, base, platform).valid).toBe(true);
    expect(buildAgentUpdatePayload(base, renamed)).toEqual({ name: 'Renamed' });
    expect(buildAgentUpdatePayload(base, renamed, platform)).toEqual({
      name: 'Renamed',
    });
  });

  it('serializes ordinary business edits only, even when a stale draft contains technical fields', () => {
    const base = buildAgentDraft(assistant);
    const stale = {
      ...base,
      name: 'Renamed',
      routingDescription: ' New routing ',
      instruction: '',
      model: null,
      temperature: null,
      thinkingEffort: null,
      capabilities,
    };
    expect(buildAgentUpdatePayload(base, stale)).toEqual({
      name: 'Renamed',
      routing_description: 'New routing',
    });
    expect(validateAgentDraft(stale, base).valid).toBe(true);
  });

  it('platform edits instructions but never per-agent model settings', () => {
    const base = buildAgentDraft(assistant);
    expect(
      buildAgentUpdatePayload(
        base,
        {
          ...base,
          instruction: 'New',
          model: null,
          thinkingEffort: null,
          temperature: null,
        },
        platform
      )
    ).toEqual({ description: 'New' });
    expect(
      buildAgentUpdatePayload(
        base,
        { ...base, model: 'other', temperature: 1 },
        platform
      )
    ).toEqual({});
  });

  it('validates instruction only for platform editing and preserves legacy limits', () => {
    const base = buildAgentDraft(assistant);
    expect(
      validateAgentDraft({ ...base, instruction: '' }, base, platform).errors
        .instruction
    ).toBe('required');
    expect(
      validateAgentDraft(
        { ...base, instruction: 'a'.repeat(20001) },
        base,
        platform
      ).errors.instruction
    ).toBe('max');
    expect(agentInstructionMaxLength({ instruction: 'a'.repeat(24000) })).toBe(
      24000
    );
    expect(
      validateAgentDraft({
        ...base,
        routingDescription: 'a'.repeat(AGENT_DESCRIPTION_MAX_LENGTH + 1),
      }).errors.routingDescription
    ).toBe('max');
    expect(validateAgentDraft({ ...base, name: ' ' }).errors.name).toBe(
      'required'
    );
  });

  it('counts only changes that can be serialized for the current access', () => {
    const base = buildAgentDraft(assistant);
    expect(isAgentDraftDirty(base, { ...base, name: ' Agent ' })).toBe(false);
    expect(isAgentDraftDirty(base, { ...base, instruction: 'Changed' })).toBe(
      false
    );
    expect(
      isAgentDraftDirty(base, { ...base, instruction: 'Changed' }, platform)
    ).toBe(true);
    expect(isAgentDraftDirty(base, { ...base, temperature: 1 }, platform)).toBe(
      false
    );
  });

  it('PATCHes canonical scopes only after an explicit platform edit, preserving the other scope', () => {
    const base = buildAgentDraft({ ...assistant, config: { capabilities } });
    const changed = {
      ...base.capabilities,
      scopes: {
        ...base.capabilities.scopes,
        agent: { enabled: true, tool_ids: ['send_notification'] },
      },
    };
    const draft = { ...base, capabilities: changed };
    expect(buildAgentUpdatePayload(base, draft)).toEqual({});
    expect(buildAgentUpdatePayload(base, draft, platform)).toEqual({
      config: { capabilities: changed },
    });
    expect(capabilities.scopes.agent.tool_ids).toEqual([]);
    expect(
      buildAgentUpdatePayload(buildAgentDraft(assistant), draft, platform)
    ).not.toHaveProperty('config');
  });

  it('rebases new business values without losing in-flight instruction or capability edits', () => {
    const base = buildAgentDraft({ ...assistant, config: { capabilities } });
    const next = { ...base, name: 'Saved', instruction: 'Server' };
    expect(
      rebaseAgentDraft(base, next, { ...base, instruction: 'Draft' })
    ).toEqual({ ...next, instruction: 'Draft' });
  });
});

describe('model metadata for diagnostic views', () => {
  it('uses the catalog and falls back to saved diagnostics', () => {
    const model = { id: 'known' };
    expect(findAgentModelMetadata({ models: [model], modelId: 'known' })).toBe(
      model
    );
    const legacy = { id: 'old' };
    expect(
      findAgentModelMetadata({
        modelId: 'old',
        assistant: { playground_model: legacy },
      })
    ).toBe(legacy);
  });
});
