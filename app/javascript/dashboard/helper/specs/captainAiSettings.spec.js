import { describe, expect, it } from 'vitest';
import {
  AI_SETTINGS_API_VALUES,
  MESSAGE_INSTRUCTION_MAX_LENGTH,
  buildAiSettingsPatch,
  isAiSettingsDirty,
  mapAiSettingsErrors,
  normalizeReason,
  readAiSettingsAvailability,
  toAiSettingsDraft,
  validateAiSettingsDraft,
} from '../captainAiSettings';

// The server still returns the platform safety values; the page ignores them.
const contractPayload = () => ({
  understanding: {
    voice_messages: true,
    images: true,
    documents: false,
    web_search: true,
    web_page_reading: false,
  },
  handoff: {
    handoff_reasons: [
      { id: 'other', label: 'Другое', enabled: true, builtin: true },
      {
        id: 'low_confidence',
        label: 'ИИ не уверен',
        enabled: false,
        builtin: true,
      },
      { id: 'custom_handoff_1', label: 'Цена', enabled: true, builtin: false },
    ],
    completion_reasons: [
      { id: 'goal_achieved', label: 'Цель', enabled: true, builtin: true },
      { id: 'other', label: 'Другое', enabled: true, builtin: true },
    ],
    handoff_message: {
      enabled: true,
      mode: 'fixed',
      text: 'Передаю',
      instruction: '',
    },
    resolution_message: {
      enabled: false,
      mode: 'generated',
      text: '',
      instruction: 'Коротко и тепло.',
    },
    auto_completion_enabled: true,
    auto_reply_on_last_incoming: false,
  },
  faq: { generate_from_resolved: false },
  conversation: { message_collapse_window_seconds: 15 },
  safety: {
    moderation_enabled: true,
    prompt_injection_action: 'off',
    sensitive_info_action: 'flag',
    custom_rules: [
      {
        id: 'rule-in',
        name: '',
        direction: 'inbound',
        instruction: '',
        action: 'handoff',
        enabled: true,
        message: null,
      },
    ],
  },
  availability: { web_access_configured: false },
});

describe('captainAiSettings helper', () => {
  it('writes the contract values through one map', () => {
    expect(AI_SETTINGS_API_VALUES).toMatchObject({
      messageMode: { fixed: 'fixed', generated: 'generated' },
      reasonEnabledKey: 'enabled',
    });
  });

  it('builds a draft in UI values from the contract payload', () => {
    const draft = toAiSettingsDraft(contractPayload());

    expect(draft.understanding).toEqual({
      voice_messages: true,
      images: true,
      documents: false,
      web_search: true,
      web_page_reading: false,
    });
    expect(draft.handoff.handoff_reasons.map(reason => reason.id)).toEqual([
      'low_confidence',
      'custom_handoff_1',
      'other',
    ]);
    expect(draft.handoff.handoff_reasons[0]).toEqual({
      id: 'low_confidence',
      label: 'ИИ не уверен',
      enabled: false,
      builtin: true,
    });
    expect(draft.handoff.resolution_message).toEqual({
      enabled: false,
      mode: 'generated',
      text: '',
      instruction: 'Коротко и тепло.',
    });
    expect(draft.conversation.message_collapse_window_seconds).toBe(15);
    expect(draft).not.toHaveProperty('availability');
    expect(readAiSettingsAvailability(contractPayload())).toEqual({
      web_access_configured: false,
    });
    expect(readAiSettingsAvailability({})).toEqual({
      web_access_configured: true,
    });
  });

  it('reads only the one safety switch and none of the platform safety values', () => {
    const draft = toAiSettingsDraft(contractPayload());

    expect(draft.safety).toEqual({ moderation_enabled: true });
  });

  it('tolerates the legacy per-agent value sets on read', () => {
    const draft = toAiSettingsDraft({
      handoff: {
        handoff_reasons: [
          { id: 'customer_requested_human', label: 'Просит', active: false },
          { id: 'other', label: 'Other', active: false },
        ],
        handoff_message: 'Сейчас подключится сотрудник',
        resolution_message: '',
      },
      safety: { moderation_enabled: 'enabled' },
    });

    expect(draft.handoff.handoff_reasons).toEqual([
      {
        id: 'customer_requested_human',
        label: 'Просит',
        enabled: false,
        builtin: true,
      },
      { id: 'other', label: 'Other', enabled: true, builtin: true },
    ]);
    expect(draft.handoff.handoff_message).toEqual({
      enabled: true,
      mode: 'fixed',
      text: 'Сейчас подключится сотрудник',
      instruction: '',
    });
    expect(draft.handoff.resolution_message.enabled).toBe(false);
    expect(draft.safety.moderation_enabled).toBe(true);
  });

  it('localizes the backend fallback label of the system reason', () => {
    const payload = {
      handoff: {
        handoff_reasons: [
          { id: 'other', label: 'Other', enabled: true },
          { id: 'custom_1', label: 'Other', enabled: true },
        ],
        completion_reasons: [{ id: 'other', label: 'Иное', enabled: true }],
      },
    };

    const draft = toAiSettingsDraft(payload, { otherLabel: 'Другое' });

    expect(draft.handoff.handoff_reasons.map(reason => reason.label)).toEqual([
      'Other',
      'Другое',
    ]);
    expect(draft.handoff.completion_reasons[0].label).toBe('Иное');
    expect(toAiSettingsDraft(payload).handoff.handoff_reasons[1].label).toBe(
      'Other'
    );
  });

  it('fills defaults for a missing payload', () => {
    const draft = toAiSettingsDraft(null);

    expect(draft.understanding.web_search).toBe(false);
    expect(draft.understanding.voice_messages).toBe(true);
    expect(draft.handoff.handoff_reasons).toEqual([]);
    expect(draft.handoff.auto_completion_enabled).toBe(true);
    expect(draft.conversation.message_collapse_window_seconds).toBe(0);
    expect(draft.safety).toEqual({ moderation_enabled: false });
  });

  it('defaults builtin to the known reason ids and keeps an API lock', () => {
    expect(normalizeReason({ id: 'faq_no_answer', label: 'FAQ' })).toEqual({
      id: 'faq_no_answer',
      label: 'FAQ',
      enabled: true,
      builtin: true,
    });
    expect(
      normalizeReason({ id: 'custom_x', label: 'X', enabled: false })
    ).toEqual({ id: 'custom_x', label: 'X', enabled: false, builtin: false });
    expect(
      normalizeReason({
        id: 'faq_no_answer',
        label: 'FAQ',
        enabled: false,
        locked: true,
      })
    ).toMatchObject({ enabled: true, locked: true });
    expect(normalizeReason({ label: 'no id' })).toBeNull();
  });

  it('sends nothing for an untouched draft', () => {
    const base = toAiSettingsDraft(contractPayload());
    const draft = toAiSettingsDraft(contractPayload());

    expect(buildAiSettingsPatch(base, draft)).toEqual({});
    expect(isAiSettingsDirty(base, draft)).toBe(false);
  });

  it('sends only changed sections, each whole and in the contract shape', () => {
    const base = toAiSettingsDraft(contractPayload());
    const draft = toAiSettingsDraft(contractPayload());
    draft.faq.generate_from_resolved = true;
    draft.safety.moderation_enabled = false;

    const patch = buildAiSettingsPatch(base, draft);

    expect(Object.keys(patch).sort()).toEqual(['faq', 'safety']);
    expect(patch.faq).toEqual({ generate_from_resolved: true });
    // Only the switch: the platform safety values never travel back.
    expect(patch.safety).toEqual({ moderation_enabled: false });
    expect(patch).not.toHaveProperty('availability');
    expect(isAiSettingsDirty(base, draft)).toBe(true);
  });

  it('writes legacy-read values back in the contract spelling', () => {
    const legacy = {
      handoff: {
        handoff_reasons: [{ id: 'other', label: 'Other', active: true }],
        handoff_message: 'Передаю',
      },
    };
    const base = toAiSettingsDraft(legacy);
    const draft = toAiSettingsDraft(legacy);
    draft.handoff.handoff_reasons[0].label = 'Другое ';
    draft.safety.moderation_enabled = true;

    const patch = buildAiSettingsPatch(base, draft);

    expect(patch.handoff.handoff_reasons).toEqual([
      { id: 'other', label: 'Другое', enabled: true, builtin: true },
    ]);
    expect(patch.handoff.handoff_message).toEqual({
      enabled: true,
      mode: 'fixed',
      text: 'Передаю',
      instruction: '',
    });
    expect(patch.safety).toEqual({ moderation_enabled: true });
  });

  it('validates reasons, status messages and the collapse window', () => {
    const draft = toAiSettingsDraft(contractPayload());
    expect(validateAiSettingsDraft(draft).valid).toBe(true);

    draft.handoff.completion_reasons[0].label = '  ';
    draft.handoff.handoff_message.text = '';
    draft.handoff.resolution_message = {
      enabled: true,
      mode: 'generated',
      text: '',
    };
    draft.conversation.message_collapse_window_seconds = '';

    const result = validateAiSettingsDraft(draft);
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual({
      completion_reasons: true,
      handoff_message: true,
      collapse_window: true,
    });
  });

  it('keeps the "how to write" instruction of both messages through draft, patch and validation', () => {
    const base = toAiSettingsDraft(contractPayload());
    const draft = toAiSettingsDraft(contractPayload());

    expect(draft.handoff.handoff_message.instruction).toBe('');
    expect(draft.handoff.resolution_message.instruction).toBe(
      'Коротко и тепло.'
    );
    expect(toAiSettingsDraft({ handoff: {} }).handoff.handoff_message).toEqual({
      enabled: false,
      mode: 'fixed',
      text: '',
      instruction: '',
    });

    draft.handoff.handoff_message = {
      enabled: true,
      mode: 'generated',
      text: 'Запасной текст',
      instruction: 'Обращайтесь на «вы».',
    };
    const patch = buildAiSettingsPatch(base, draft);

    expect(Object.keys(patch)).toEqual(['handoff']);
    expect(patch.handoff.handoff_message).toEqual({
      enabled: true,
      mode: 'generated',
      text: 'Запасной текст',
      instruction: 'Обращайтесь на «вы».',
    });
    expect(patch.handoff.resolution_message).toEqual({
      enabled: false,
      mode: 'generated',
      text: '',
      instruction: 'Коротко и тепло.',
    });
    expect(validateAiSettingsDraft(draft).valid).toBe(true);
  });

  it('needs no fixed text for an AI-written message and limits the instruction to 500 characters', () => {
    const draft = toAiSettingsDraft(contractPayload());
    draft.handoff.handoff_message = {
      enabled: true,
      mode: 'generated',
      text: '',
      instruction: 'я'.repeat(500),
    };
    draft.handoff.resolution_message = {
      enabled: true,
      mode: 'generated',
      text: '',
      instruction: 'я'.repeat(501),
    };

    const result = validateAiSettingsDraft(draft);

    expect(result.valid).toBe(false);
    expect(result.errors).toEqual({ resolution_message_instruction: true });
    expect(MESSAGE_INSTRUCTION_MAX_LENGTH).toBe(500);
  });

  it('is not blocked by a stored platform rule the page cannot show', () => {
    // contractPayload() carries a rule with a blank name and instruction.
    const draft = toAiSettingsDraft(contractPayload());

    expect(validateAiSettingsDraft(draft)).toEqual({ valid: true, errors: {} });
  });

  it('maps server field errors to inline targets and keeps the rest general', () => {
    const mapped = mapAiSettingsErrors([
      { field: 'handoff.handoff_message.text', code: 'blank', message: 'C' },
      {
        field: 'handoff.resolution_message.instruction',
        code: 'too_long',
        message: 'C2',
      },
      {
        field: 'conversation.message_collapse_window_seconds',
        code: 'invalid',
        message: 'D',
      },
      { field: 'handoff.completion_reasons', code: 'invalid', message: 'E' },
      { field: 'understanding.web_search', code: 'invalid', message: 'F' },
      { field: 'safety.moderation_enabled', code: 'invalid', message: 'G' },
      { field: null, code: 'conflict', message: 'H' },
      { field: 'unknown.thing', code: 'invalid', message: 'I' },
    ]);

    expect(mapped.fields).toEqual({
      handoff_message: 'C',
      resolution_message_instruction: 'C2',
      collapse_window: 'D',
      completion_reasons: 'E',
      web_search: 'F',
      moderation_enabled: 'G',
    });
    expect(mapped.general).toEqual(['H', 'I']);
  });
});
