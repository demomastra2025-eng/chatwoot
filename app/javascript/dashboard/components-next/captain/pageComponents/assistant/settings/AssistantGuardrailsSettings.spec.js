import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import AssistantGuardrailsSettings from './AssistantGuardrailsSettings.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const rule = (id, direction = 'input', changes = {}) => ({
  id,
  name: `Rule ${id}`,
  direction,
  instruction: 'If the customer asks to change contract terms.',
  action: 'handoff',
  enabled: true,
  ...changes,
});
const mountEditor = (rules = []) => {
  let wrapper;
  wrapper = mount(AssistantGuardrailsSettings, {
    props: {
      modelValue: rules,
      'onUpdate:modelValue': value => wrapper.setProps({ modelValue: value }),
    },
  });
  return wrapper;
};
const savedRules = wrapper => wrapper.props('modelValue');
const row = (wrapper, id) => wrapper.get(`[data-test="guardrail-${id}"]`);

describe('custom guardrails editor', () => {
  beforeEach(() => {
    vi.spyOn(window.crypto, 'randomUUID')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000001')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000002');
  });
  afterEach(() => vi.restoreAllMocks());

  it('shows separate incoming and reply groups without a local save or model selector', () => {
    const wrapper = mountEditor();
    expect(wrapper.find('[data-test="guardrail-group-input"]').exists()).toBe(
      true
    );
    expect(wrapper.find('[data-test="guardrail-group-output"]').exists()).toBe(
      true
    );
    expect(wrapper.findAll('button')).toHaveLength(2);
    expect(wrapper.findAll('select')).toHaveLength(0);
    expect(wrapper.emitted('update:modelValue')).toBeUndefined();
    expect(wrapper.vm.validate()).toBe(true);
  });

  it('generates stable IDs and keeps name, condition, optional message and enable edits local', async () => {
    const wrapper = mountEditor();
    await wrapper.get('[data-test="guardrail-add-input"]').trigger('click');
    await wrapper.get('[data-test="guardrail-add-output"]').trigger('click');
    const id = savedRules(wrapper)[0].id;
    expect(id).toBe('00000000-0000-4000-8000-000000000001');
    expect(savedRules(wrapper).map(item => item.direction)).toEqual([
      'input',
      'output',
    ]);
    await wrapper.get(`#guardrail-${id}-name`).setValue('Contract changes');
    await wrapper
      .get(`#guardrail-${id}-instruction`)
      .setValue('If the customer asks to change contract terms.');
    await wrapper
      .get(`#guardrail-${id}-message`)
      .setValue('A teammate will help with your request.');
    await row(wrapper, id).get('[role="switch"]').trigger('click');

    expect(savedRules(wrapper)[0]).toEqual({
      id,
      name: 'Contract changes',
      direction: 'input',
      instruction: 'If the customer asks to change contract terms.',
      message: 'A teammate will help with your request.',
      action: 'handoff',
      enabled: false,
    });
    expect(window.crypto.randomUUID).toHaveBeenCalledTimes(2);
    expect(wrapper.emitted('submit')).toBeUndefined();
  });

  it('offers only handoff on input and handoff or one rewrite on output', async () => {
    const wrapper = mountEditor([rule('incoming'), rule('reply', 'output')]);
    const options = id =>
      row(wrapper, id)
        .findAll('option')
        .map(item => item.element.value);
    expect(options('incoming')).toEqual(['handoff']);
    expect(options('reply')).toEqual(['handoff', 'rewrite']);
    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.OUTPUT.DESCRIPTION'
    );
    await row(wrapper, 'reply').get('select').setValue('rewrite');
    expect(savedRules(wrapper)[1].action).toBe('rewrite');
    row(wrapper, 'incoming')
      .findComponent({ name: 'Select' })
      .vm.$emit('update:modelValue', 'rewrite');
    await wrapper.vm.$nextTick();
    expect(savedRules(wrapper)[0].action).toBe('handoff');
  });

  it('moves priority within each direction while preserving the other group', async () => {
    const wrapper = mountEditor([
      rule('input-a'),
      rule('output-a', 'output'),
      rule('input-b'),
      rule('output-b', 'output', { enabled: false }),
    ]);
    expect(
      wrapper.get('[data-test="guardrail-up-input-a"]').attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper
        .get('[data-test="guardrail-down-output-b"]')
        .attributes('disabled')
    ).toBeDefined();
    await wrapper.get('[data-test="guardrail-down-input-a"]').trigger('click');
    expect(savedRules(wrapper).map(item => item.id)).toEqual([
      'input-b',
      'output-a',
      'input-a',
      'output-b',
    ]);
    await wrapper.get('[data-test="guardrail-up-output-b"]').trigger('click');
    expect(savedRules(wrapper).map(item => item.id)).toEqual([
      'input-b',
      'output-b',
      'input-a',
      'output-a',
    ]);
    expect(savedRules(wrapper)[1].enabled).toBe(false);
  });

  it('emits an explicit empty array when the last rule is deleted', async () => {
    const original = Object.freeze([Object.freeze(rule('only-rule'))]);
    const wrapper = mountEditor(original);
    await wrapper
      .get('[data-test="guardrail-delete-only-rule"]')
      .trigger('click');
    expect(savedRules(wrapper)).toEqual([]);
    expect(wrapper.emitted('update:modelValue').at(-1)).toEqual([[]]);
    expect(original).toEqual([rule('only-rule')]);
  });

  it('does not mutate a copied rule or replace a legacy service action on an unrelated edit', async () => {
    const original = Object.freeze([
      Object.freeze(rule('legacy-rule', 'output', { action: 'block' })),
    ]);
    const wrapper = mountEditor(original);
    expect(row(wrapper, 'legacy-rule').get('select').element.value).toBe(
      'handoff'
    );
    await wrapper.get('#guardrail-legacy-rule-name').setValue('New name');
    expect(savedRules(wrapper)[0].action).toBe('block');
    expect(original[0].name).toBe('Rule legacy-rule');
    await row(wrapper, 'legacy-rule').get('select').setValue('rewrite');
    expect(savedRules(wrapper)[0].action).toBe('rewrite');
    expect(wrapper.vm.validate()).toBe(true);
  });

  it('requires a name and plain-language condition even for disabled rules', async () => {
    const wrapper = mountEditor([
      rule('empty-rule', 'input', {
        name: '  ',
        instruction: '',
        enabled: false,
      }),
    ]);
    expect(wrapper.vm.validate()).toBe(false);
    await wrapper.vm.$nextTick();
    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.ERRORS.NAME'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.ERRORS.INSTRUCTION'
    );
    await wrapper.get('#guardrail-empty-rule-name').setValue('Contract terms');
    await wrapper
      .get('#guardrail-empty-rule-instruction')
      .setValue('If the customer asks to change contract terms.');
    expect(wrapper.vm.validate()).toBe(true);
    expect(wrapper.text()).not.toContain('CUSTOM_GUARDRAILS.ERRORS.');
  });

  it.each([
    ['name', 121],
    ['instruction', 2001],
    ['message', 2001],
  ])(
    'rejects an overlong %s instead of silently truncating saved text',
    async (field, length) => {
      const wrapper = mountEditor([
        rule('long-rule', 'input', { [field]: 'x'.repeat(length) }),
      ]);
      expect(wrapper.vm.validate()).toBe(false);
      await wrapper.vm.$nextTick();
      expect(wrapper.text()).toContain(
        `CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.ERRORS.${field.toUpperCase()}`
      );
      expect(savedRules(wrapper)[0][field]).toHaveLength(length);
    }
  );

  it('accepts exact text limits and an omitted or empty public message', async () => {
    const wrapper = mountEditor([
      rule('exact-rule', 'output', {
        name: 'n'.repeat(120),
        instruction: 'i'.repeat(2000),
        message: 'm'.repeat(2000),
      }),
      rule('omitted-message'),
      rule('empty-message', 'input', { message: '' }),
    ]);
    expect(wrapper.vm.validate()).toBe(true);
    expect(
      wrapper.get('#guardrail-exact-rule-name').attributes('maxlength')
    ).toBe('120');
    expect(
      wrapper.get('#guardrail-exact-rule-instruction').attributes('maxlength')
    ).toBe('2000');
    expect(savedRules(wrapper)[1]).not.toHaveProperty('message');
  });

  it('enforces a combined twenty-rule limit across both groups', async () => {
    const wrapper = mountEditor(
      Array.from({ length: 20 }, (_, index) =>
        rule(`rule-${index}`, index % 2 === 0 ? 'input' : 'output')
      )
    );
    expect(wrapper.vm.validate()).toBe(true);
    const inputAdd = wrapper.get('[data-test="guardrail-add-input"]');
    const outputAdd = wrapper.get('[data-test="guardrail-add-output"]');
    [inputAdd, outputAdd].forEach(add => {
      expect(add.attributes('disabled')).toBeDefined();
    });
    await inputAdd.trigger('click');
    await outputAdd.trigger('click');
    expect(savedRules(wrapper)).toHaveLength(20);
    expect(window.crypto.randomUUID).not.toHaveBeenCalled();
    await wrapper.get('[data-test="guardrail-delete-rule-0"]').trigger('click');
    expect(
      wrapper.get('[data-test="guardrail-add-input"]').attributes('disabled')
    ).toBeUndefined();
  });

  it.each([
    ['duplicate identifiers', [rule('same-id'), rule('same-id', 'output')]],
    ['reserved identifier', [rule('none')]],
    ['input rewrite', [rule('invalid-action', 'input', { action: 'rewrite' })]],
    [
      'nonboolean enabled',
      [rule('invalid-enabled', 'input', { enabled: 'true' })],
    ],
    [
      'over twenty rules',
      Array.from({ length: 21 }, (_, index) => rule(`too-many-${index}`)),
    ],
  ])('prevents saving %s', async (_case, rules) => {
    const wrapper = mountEditor(rules);
    expect(wrapper.vm.validate()).toBe(false);
    await wrapper.vm.$nextTick();
    expect(wrapper.get('[role="alert"]').text()).toBe(
      'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS.ERRORS.RULES'
    );
  });
});
