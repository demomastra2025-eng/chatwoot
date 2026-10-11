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
  id: 12,
  name: 'Администратор',
  routing_description: 'Записывает пациентов',
  description: 'Отвечай вежливо.',
  config: {
    model: 'smart-model',
    thinking_effort: 'low',
    temperature: '0.4',
    follow_up_settings: { enabled: true },
  },
};

const smartModel = {
  id: 'smart-model',
  supports_temperature: true,
  reasoning_efforts: ['none', 'low', 'high'],
};
const plainModel = {
  id: 'plain-model',
  supports_temperature: false,
  reasoning_efforts: [],
};

describe('buildAgentDraft', () => {
  it('maps the assistant record to the editable draft', () => {
    expect(buildAgentDraft(assistant)).toEqual({
      name: 'Администратор',
      routingDescription: 'Записывает пациентов',
      instruction: 'Отвечай вежливо.',
      model: 'smart-model',
      thinkingEffort: 'low',
      temperature: 0.4,
    });
  });

  it('uses empty values for a record without config', () => {
    expect(buildAgentDraft({ id: 1 })).toEqual({
      name: '',
      routingDescription: '',
      instruction: '',
      model: '',
      thinkingEffort: '',
      temperature: null,
    });
  });
});

describe('isAgentDraftDirty', () => {
  it('is clean for an untouched draft and ignores surrounding spaces', () => {
    const base = buildAgentDraft(assistant);
    expect(isAgentDraftDirty(base, { ...base })).toBe(false);
    expect(
      isAgentDraftDirty(base, { ...base, name: ' Администратор  ' })
    ).toBe(false);
  });

  it('detects changes of every editable field', () => {
    const base = buildAgentDraft(assistant);
    expect(isAgentDraftDirty(base, { ...base, name: 'Врач' })).toBe(true);
    expect(
      isAgentDraftDirty(base, { ...base, routingDescription: 'Другое' })
    ).toBe(true);
    expect(isAgentDraftDirty(base, { ...base, instruction: 'Новая' })).toBe(
      true
    );
    expect(isAgentDraftDirty(base, { ...base, model: '' })).toBe(true);
    expect(isAgentDraftDirty(base, { ...base, temperature: 0.9 })).toBe(true);
  });

  it('does not count parameters the model does not support as changes', () => {
    const base = buildAgentDraft({
      ...assistant,
      config: { model: 'plain-model', temperature: 0.7, thinking_effort: 'x' },
    });
    const cleared = { ...base, temperature: null, thinkingEffort: '' };
    expect(isAgentDraftDirty(base, cleared, plainModel)).toBe(false);
    // Unknown metadata keeps the raw comparison.
    expect(isAgentDraftDirty(base, cleared, {})).toBe(true);
  });
});

describe('validateAgentDraft', () => {
  const valid = buildAgentDraft(assistant);

  it('accepts a complete draft', () => {
    expect(validateAgentDraft(valid, valid)).toEqual({
      valid: true,
      errors: {},
    });
  });

  it('requires name, description and instruction', () => {
    const result = validateAgentDraft(
      { ...valid, name: '  ', routingDescription: '', instruction: ' ' },
      valid
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual({
      name: 'required',
      routingDescription: 'required',
      instruction: 'required',
    });
  });

  it('limits the description to 400 characters', () => {
    const result = validateAgentDraft(
      {
        ...valid,
        routingDescription: 'a'.repeat(AGENT_DESCRIPTION_MAX_LENGTH + 1),
      },
      valid
    );
    expect(result.errors.routingDescription).toBe('max');
    expect(
      validateAgentDraft(
        {
          ...valid,
          routingDescription: 'a'.repeat(AGENT_DESCRIPTION_MAX_LENGTH),
        },
        valid
      ).valid
    ).toBe(true);
  });

  it('limits the instruction to 20000 characters or the saved length', () => {
    expect(
      validateAgentDraft({ ...valid, instruction: 'a'.repeat(20001) }, valid)
        .errors.instruction
    ).toBe('max');

    const longBase = { ...valid, instruction: 'b'.repeat(24000) };
    expect(agentInstructionMaxLength(longBase)).toBe(24000);
    expect(
      validateAgentDraft(
        { ...longBase, instruction: 'c'.repeat(24000) },
        longBase
      ).valid
    ).toBe(true);
  });
});

describe('buildAgentUpdatePayload', () => {
  const base = buildAgentDraft(assistant);

  it('sends only the changed text fields', () => {
    expect(
      buildAgentUpdatePayload(
        base,
        { ...base, name: ' Врач ', instruction: 'Новая инструкция' },
        smartModel
      )
    ).toEqual({ name: 'Врач', description: 'Новая инструкция' });
    expect(
      buildAgentUpdatePayload(
        base,
        { ...base, routingDescription: 'Отвечает про цены' },
        smartModel
      )
    ).toEqual({ routing_description: 'Отвечает про цены' });
  });

  it('returns an empty payload when nothing changed', () => {
    expect(buildAgentUpdatePayload(base, { ...base }, smartModel)).toEqual({});
  });

  it('sends the model group with only supported parameters', () => {
    expect(
      buildAgentUpdatePayload(
        base,
        { ...base, model: 'plain-model', temperature: 0.4 },
        plainModel
      )
    ).toEqual({
      config: {
        model: 'plain-model',
        thinking_effort: null,
        temperature: null,
      },
    });
    expect(
      buildAgentUpdatePayload(
        base,
        { ...base, thinkingEffort: 'high', temperature: 0.8 },
        smartModel
      )
    ).toEqual({
      config: {
        model: 'smart-model',
        thinking_effort: 'high',
        temperature: 0.8,
      },
    });
  });

  it('stores the platform default model as null', () => {
    expect(
      buildAgentUpdatePayload(base, { ...base, model: '' }, smartModel).config
        .model
    ).toBeNull();
  });
});

describe('findAgentModelMetadata', () => {
  it('prefers the catalog entry and falls back to the playground model', () => {
    expect(
      findAgentModelMetadata({ models: [smartModel], modelId: 'smart-model' })
    ).toBe(smartModel);
    const playgroundModel = { id: 'legacy', supports_temperature: false };
    expect(
      findAgentModelMetadata({
        models: [smartModel],
        modelId: 'legacy',
        assistant: { playground_model: playgroundModel },
      })
    ).toBe(playgroundModel);
    expect(findAgentModelMetadata({ models: [], modelId: '' })).toEqual({});
  });
});

describe('rebaseAgentDraft', () => {
  it('takes new saved values for untouched fields and keeps edits', () => {
    const previous = buildAgentDraft(assistant);
    const next = { ...previous, name: 'Переименован', model: 'plain-model' };
    const draft = { ...previous, instruction: 'Черновик' };
    expect(rebaseAgentDraft(previous, next, draft)).toEqual({
      ...next,
      instruction: 'Черновик',
    });
  });
});
