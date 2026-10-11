import { describe, expect, it } from 'vitest';
import {
  AI_SETTINGS_API_VALUES,
  buildAiSettingsPatch,
  isAiSettingsDirty,
  mapAiSettingsErrors,
  normalizeReason,
  readAiSettingsAvailability,
  ruleActionsFor,
  toAiSettingsDraft,
  validateAiSettingsDraft,
  validateCustomRules,
} from '../captainAiSettings';

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
    handoff_message: { enabled: true, mode: 'fixed', text: 'Передаю' },
    resolution_message: { enabled: false, mode: 'generated', text: '' },
    auto_completion_enabled: true,
    auto_reply_on_last_incoming: false,
  },
  faq: { generate_from_resolved: false },
  conversation: { message_collapse_window_seconds: 15 },
  safety: {
    moderation_enabled: true,
    prompt_injection_action: 'block',
    sensitive_info_action: 'off',
    custom_rules: [
      {
        id: 'rule-in',
        name: 'Договор',
        direction: 'inbound',
        instruction: 'Если клиент просит изменить договор.',
        action: 'handoff',
        enabled: true,
        message: '',
      },
      {
        id: 'rule-out',
        name: 'Гарантии',
        direction: 'outbound',
        instruction: 'Если ответ обещает гарантию.',
        action: 'rewrite_once',
        enabled: false,
        message: 'Уточню у коллег.',
      },
    ],
  },
  availability: { web_access_configured: false },
});

describe('captainAiSettings helper', () => {
  it('writes the contract values through one map', () => {
    expect(AI_SETTINGS_API_VALUES).toMatchObject({
      direction: { inbound: 'inbound', outbound: 'outbound' },
      ruleAction: { handoff: 'handoff', rewrite: 'rewrite_once' },
      safetyAction: { block: 'block', flag: 'flag', off: 'off' },
      reasonEnabledKey: 'enabled',
    });
    expect(ruleActionsFor('inbound')).toEqual(['handoff']);
    expect(ruleActionsFor('outbound')).toEqual(['handoff', 'rewrite']);
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
    });
    expect(draft.conversation.message_collapse_window_seconds).toBe(15);
    expect(draft.safety.sensitive_info_action).toBe('off');
    expect(draft.safety.custom_rules[1]).toMatchObject({
      direction: 'outbound',
      action: 'rewrite',
      enabled: false,
    });
    expect(draft).not.toHaveProperty('availability');
    expect(readAiSettingsAvailability(contractPayload())).toEqual({
      web_access_configured: false,
    });
    expect(readAiSettingsAvailability({})).toEqual({
      web_access_configured: true,
    });
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
      safety: {
        moderation_enabled: 'enabled',
        prompt_injection_action: 'disabled',
        sensitive_info_action: 'flag',
        custom_rules: [
          {
            id: 'legacy-in',
            name: 'Старое',
            direction: 'input',
            instruction: 'Условие',
            action: 'block',
            enabled: true,
          },
          {
            id: 'legacy-out',
            name: 'Ответ',
            direction: 'output',
            instruction: 'Условие',
            action: 'rewrite',
            enabled: true,
          },
          {
            id: 'bad-in',
            name: 'Ошибка',
            direction: 'input',
            instruction: 'Условие',
            action: 'rewrite',
            enabled: true,
          },
        ],
      },
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
    });
    expect(draft.handoff.resolution_message.enabled).toBe(false);
    expect(draft.safety.moderation_enabled).toBe(true);
    expect(draft.safety.prompt_injection_action).toBe('off');
    expect(
      draft.safety.custom_rules.map(rule => [rule.direction, rule.action])
    ).toEqual([
      ['inbound', 'handoff'],
      ['outbound', 'rewrite'],
      ['inbound', 'handoff'],
    ]);
    expect(draft.safety.custom_rules[0].message).toBe('');
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
    expect(draft.safety.prompt_injection_action).toBe('block');
    expect(draft.safety.custom_rules).toEqual([]);
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
    draft.safety.custom_rules[0].name = 'Договор и цены';

    const patch = buildAiSettingsPatch(base, draft);

    expect(Object.keys(patch).sort()).toEqual(['faq', 'safety']);
    expect(patch.faq).toEqual({ generate_from_resolved: true });
    expect(patch.safety).toEqual({
      moderation_enabled: true,
      prompt_injection_action: 'block',
      sensitive_info_action: 'off',
      custom_rules: [
        {
          id: 'rule-in',
          name: 'Договор и цены',
          direction: 'inbound',
          instruction: 'Если клиент просит изменить договор.',
          action: 'handoff',
          enabled: true,
          message: '',
        },
        {
          id: 'rule-out',
          name: 'Гарантии',
          direction: 'outbound',
          instruction: 'Если ответ обещает гарантию.',
          action: 'rewrite_once',
          enabled: false,
          message: 'Уточню у коллег.',
        },
      ],
    });
    expect(patch).not.toHaveProperty('availability');
    expect(isAiSettingsDirty(base, draft)).toBe(true);
  });

  it('writes legacy-read values back in the contract spelling', () => {
    const legacy = {
      handoff: {
        handoff_reasons: [{ id: 'other', label: 'Other', active: true }],
        handoff_message: 'Передаю',
      },
      safety: {
        prompt_injection_action: 'disabled',
        custom_rules: [
          {
            id: 'legacy-out',
            name: 'Ответ',
            direction: 'output',
            instruction: 'Условие',
            action: 'rewrite',
            enabled: true,
          },
        ],
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
    });
    expect(patch.safety.prompt_injection_action).toBe('off');
    expect(patch.safety.custom_rules[0]).toMatchObject({
      direction: 'outbound',
      action: 'rewrite_once',
    });
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

  it('ports the custom rule limits of the backend validator', () => {
    const rule = (id, changes = {}) => ({
      id,
      name: 'Правило',
      direction: 'inbound',
      instruction: 'Условие',
      action: 'handoff',
      enabled: true,
      message: '',
      ...changes,
    });

    expect(validateCustomRules([rule('a'), rule('b')]).valid).toBe(true);
    expect(
      validateCustomRules([
        rule('long', {
          name: 'n'.repeat(120),
          instruction: 'i'.repeat(2000),
          message: 'm'.repeat(2000),
        }),
      ]).valid
    ).toBe(true);

    const fields = validateCustomRules([
      rule('bad', {
        name: ' ',
        instruction: 'i'.repeat(2001),
        message: 'm'.repeat(2001),
      }),
    ]);
    expect(fields.valid).toBe(false);
    expect(fields.fields.bad).toEqual({
      name: true,
      instruction: true,
      message: true,
    });

    const duplicates = validateCustomRules([rule('x'), rule('x')]);
    const reserved = validateCustomRules([rule('none')]);
    const badId = validateCustomRules([rule('bad id!')]);
    const inboundRewrite = validateCustomRules([
      rule('in-rewrite', { action: 'rewrite' }),
    ]);
    const outboundRewrite = validateCustomRules([
      rule('out-rewrite', { direction: 'outbound', action: 'rewrite' }),
    ]);
    expect(duplicates.invalidRuleIds).toEqual(['x', 'x']);
    expect(reserved.invalidRuleIds).toEqual(['none']);
    expect(badId.valid).toBe(false);
    expect(inboundRewrite.invalidRuleIds).toEqual(['in-rewrite']);
    expect(outboundRewrite.valid).toBe(true);
    const tooMany = validateCustomRules(
      Array.from({ length: 21 }, (_, index) => rule(`r-${index}`))
    );
    expect(tooMany.tooMany).toBe(true);
    expect(tooMany.valid).toBe(false);
  });

  it('maps server field errors to inline targets and keeps the rest general', () => {
    const draft = toAiSettingsDraft(contractPayload());

    const mapped = mapAiSettingsErrors(
      [
        { field: 'safety.custom_rules[1].name', code: 'blank', message: 'A' },
        {
          field: 'safety_settings.custom_rules.0.instruction',
          code: 'too_long',
          message: 'B',
        },
        { field: 'handoff.handoff_message.text', code: 'blank', message: 'C' },
        {
          field: 'conversation.message_collapse_window_seconds',
          code: 'invalid',
          message: 'D',
        },
        { field: 'handoff.completion_reasons', code: 'invalid', message: 'E' },
        { field: 'understanding.web_search', code: 'invalid', message: 'F' },
        { field: 'safety.custom_rules', code: 'too_many', message: 'G' },
        { field: null, code: 'conflict', message: 'H' },
        { field: 'unknown.thing', code: 'invalid', message: 'I' },
      ],
      draft
    );

    expect(mapped.rules).toEqual({
      'rule-out': { name: 'A' },
      'rule-in': { instruction: 'B' },
    });
    expect(mapped.fields).toEqual({
      handoff_message: 'C',
      collapse_window: 'D',
      completion_reasons: 'E',
      web_search: 'F',
      custom_rules: 'G',
    });
    expect(mapped.general).toEqual(['H', 'I']);
  });
});
