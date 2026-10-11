import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import CustomRulesList from './CustomRulesList.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

const key = 'CAPTAIN.ASSISTANTS.FORM.CUSTOM_GUARDRAILS';

const rule = (id, direction = 'inbound', changes = {}) => ({
  id,
  name: `Rule ${id}`,
  direction,
  instruction: 'If the customer asks to change contract terms.',
  action: 'handoff',
  enabled: true,
  ...changes,
});

const mountList = (rules = [], direction = 'inbound', props = {}) => {
  let wrapper = null;
  wrapper = mount(CustomRulesList, {
    props: {
      direction,
      title: `Rules ${direction}`,
      description: `Description ${direction}`,
      modelValue: rules,
      'onUpdate:modelValue': value => wrapper.setProps({ modelValue: value }),
      ...props,
    },
  });
  return wrapper;
};
const savedRules = wrapper => wrapper.props('modelValue');
const card = (wrapper, id) => wrapper.get(`[data-testid="custom-rule-${id}"]`);

describe('CustomRulesList', () => {
  beforeEach(() => {
    vi.spyOn(window.crypto, 'randomUUID')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000001')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000002');
  });
  afterEach(() => vi.restoreAllMocks());

  it('shows only the rules of its direction and an empty note otherwise', () => {
    const rules = [rule('in-1'), rule('out-1', 'outbound')];
    const inbound = mountList(rules, 'inbound');
    const outbound = mountList(rules, 'outbound');
    const empty = mountList([rule('out-1', 'outbound')], 'inbound');

    expect(inbound.find('[data-testid="custom-rule-in-1"]').exists()).toBe(
      true
    );
    expect(inbound.find('[data-testid="custom-rule-out-1"]').exists()).toBe(
      false
    );
    expect(outbound.find('[data-testid="custom-rule-out-1"]').exists()).toBe(
      true
    );
    expect(empty.text()).toContain(`${key}.EMPTY`);
    expect(empty.get('h3').text()).toBe('Rules inbound');
    expect(inbound.emitted('update:modelValue')).toBeUndefined();
    expect(inbound.vm.validate()).toBe(true);
  });

  it('adds a rule with a stable id after the last rule of its direction', async () => {
    const wrapper = mountList([
      rule('in-a'),
      rule('out-a', 'outbound'),
      rule('out-b', 'outbound'),
    ]);

    await wrapper
      .get('[data-testid="custom-rule-add-inbound"]')
      .trigger('click');

    const id = '00000000-0000-4000-8000-000000000001';
    expect(savedRules(wrapper).map(item => item.id)).toEqual([
      'in-a',
      id,
      'out-a',
      'out-b',
    ]);
    expect(savedRules(wrapper)[1]).toEqual({
      id,
      name: '',
      direction: 'inbound',
      instruction: '',
      action: 'handoff',
      enabled: true,
      message: '',
    });
  });

  it('keeps name, condition, message and enable edits in the model', async () => {
    const wrapper = mountList([], 'outbound');
    await wrapper
      .get('[data-testid="custom-rule-add-outbound"]')
      .trigger('click');
    const id = savedRules(wrapper)[0].id;

    await wrapper.get(`#custom-rule-${id}-name`).setValue('Guarantees');
    await wrapper
      .get(`#custom-rule-${id}-instruction`)
      .setValue('If the reply promises a guaranteed result.');
    await wrapper
      .get(`#custom-rule-${id}-message`)
      .setValue('Let me check with a colleague.');
    await card(wrapper, id).get('[role="switch"]').trigger('click');

    expect(savedRules(wrapper)[0]).toEqual({
      id,
      name: 'Guarantees',
      direction: 'outbound',
      instruction: 'If the reply promises a guaranteed result.',
      action: 'handoff',
      enabled: false,
      message: 'Let me check with a colleague.',
    });
    expect(window.crypto.randomUUID).toHaveBeenCalledTimes(1);
  });

  it('offers only handoff inbound and handoff or one rewrite outbound', async () => {
    const rules = [rule('incoming'), rule('reply', 'outbound')];
    const inbound = mountList(rules, 'inbound');
    const outbound = mountList(rules, 'outbound');
    const options = (wrapper, id) =>
      card(wrapper, id)
        .findAll('option')
        .map(item => item.element.value);

    expect(options(inbound, 'incoming')).toEqual(['handoff']);
    expect(options(outbound, 'reply')).toEqual(['handoff', 'rewrite']);
    await card(outbound, 'reply').get('select').setValue('rewrite');
    expect(savedRules(outbound)[1].action).toBe('rewrite');

    card(inbound, 'incoming')
      .findComponent({ name: 'Select' })
      .vm.$emit('update:modelValue', 'rewrite');
    await inbound.vm.$nextTick();
    expect(savedRules(inbound)[0].action).toBe('handoff');
  });

  it('moves priority within its direction and keeps the other group in place', async () => {
    const rules = [
      rule('in-a'),
      rule('out-a', 'outbound'),
      rule('in-b'),
      rule('out-b', 'outbound', { enabled: false }),
    ];
    const inbound = mountList(rules, 'inbound');
    const outbound = mountList(rules, 'outbound');

    expect(
      inbound.get('[data-testid="custom-rule-up-in-a"]').attributes('disabled')
    ).toBeDefined();
    expect(
      outbound
        .get('[data-testid="custom-rule-down-out-b"]')
        .attributes('disabled')
    ).toBeDefined();

    await inbound.get('[data-testid="custom-rule-down-in-a"]').trigger('click');
    expect(savedRules(inbound).map(item => item.id)).toEqual([
      'in-b',
      'out-a',
      'in-a',
      'out-b',
    ]);
    expect(card(inbound, 'in-b').text()).toContain(`${key}.PRIORITY`);

    await outbound.get('[data-testid="custom-rule-up-out-b"]').trigger('click');
    expect(savedRules(outbound).map(item => item.id)).toEqual([
      'in-a',
      'out-b',
      'in-b',
      'out-a',
    ]);
    expect(savedRules(outbound)[1].enabled).toBe(false);
  });

  it('emits an explicit empty array when the last rule is deleted', async () => {
    const original = Object.freeze([Object.freeze(rule('only-rule'))]);
    const wrapper = mountList(original);

    await wrapper
      .get('[data-testid="custom-rule-delete-only-rule"]')
      .trigger('click');

    expect(savedRules(wrapper)).toEqual([]);
    expect(wrapper.emitted('update:modelValue').at(-1)).toEqual([[]]);
    expect(original).toEqual([rule('only-rule')]);
  });

  it('requires a name and a condition even for disabled rules', async () => {
    const wrapper = mountList([
      rule('empty-rule', 'inbound', {
        name: '  ',
        instruction: '',
        enabled: false,
      }),
    ]);

    expect(wrapper.text()).not.toContain(`${key}.ERRORS.`);
    expect(wrapper.vm.validate()).toBe(false);
    await wrapper.vm.$nextTick();
    expect(wrapper.text()).toContain(`${key}.ERRORS.NAME`);
    expect(wrapper.text()).toContain(`${key}.ERRORS.INSTRUCTION`);

    await wrapper.get('#custom-rule-empty-rule-name').setValue('Contract');
    await wrapper
      .get('#custom-rule-empty-rule-instruction')
      .setValue('If the customer asks to change contract terms.');
    expect(wrapper.vm.validate()).toBe(true);
    expect(wrapper.text()).not.toContain(`${key}.ERRORS.`);
  });

  it('shows validation errors when the page asks for them', () => {
    const rules = [rule('blank', 'inbound', { name: '' })];
    const wrapper = mountList(rules, 'inbound', { showErrors: true });

    expect(wrapper.text()).toContain(`${key}.ERRORS.NAME`);
  });

  it.each([
    ['name', 121],
    ['instruction', 2001],
    ['message', 2001],
  ])(
    'rejects an overlong %s instead of silently truncating it',
    async (field, length) => {
      const wrapper = mountList([
        rule('long-rule', 'inbound', { [field]: 'x'.repeat(length) }),
      ]);

      expect(wrapper.vm.validate()).toBe(false);
      await wrapper.vm.$nextTick();
      expect(wrapper.text()).toContain(`${key}.ERRORS.${field.toUpperCase()}`);
      expect(savedRules(wrapper)[0][field]).toHaveLength(length);
    }
  );

  it('accepts exact text limits and an omitted or empty message', () => {
    const wrapper = mountList(
      [
        rule('exact-rule', 'outbound', {
          name: 'n'.repeat(120),
          instruction: 'i'.repeat(2000),
          message: 'm'.repeat(2000),
        }),
        rule('omitted-message', 'outbound'),
        rule('empty-message', 'outbound', { message: '' }),
      ],
      'outbound'
    );

    expect(wrapper.vm.validate()).toBe(true);
    expect(
      wrapper.get('#custom-rule-exact-rule-name').attributes('maxlength')
    ).toBe('120');
    expect(
      wrapper.get('#custom-rule-exact-rule-instruction').attributes('maxlength')
    ).toBe('2000');
    expect(savedRules(wrapper)[1]).not.toHaveProperty('message');
  });

  it('enforces a combined twenty-rule limit across both directions', async () => {
    const wrapper = mountList(
      Array.from({ length: 20 }, (_, index) =>
        rule(`rule-${index}`, index % 2 === 0 ? 'inbound' : 'outbound')
      )
    );

    expect(wrapper.vm.validate()).toBe(true);
    const add = wrapper.get('[data-testid="custom-rule-add-inbound"]');
    expect(add.attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain('CAPTAIN.AI_SETTINGS.SAFETY.RULES_LIMIT');
    await add.trigger('click');
    expect(savedRules(wrapper)).toHaveLength(20);
    expect(window.crypto.randomUUID).not.toHaveBeenCalled();

    await wrapper
      .get('[data-testid="custom-rule-delete-rule-0"]')
      .trigger('click');
    expect(
      wrapper
        .get('[data-testid="custom-rule-add-inbound"]')
        .attributes('disabled')
    ).toBeUndefined();
  });

  it.each([
    ['duplicate identifiers', [rule('same-id'), rule('same-id', 'outbound')]],
    ['reserved identifier', [rule('none')]],
    [
      'inbound rewrite',
      [rule('invalid-action', 'inbound', { action: 'rewrite' })],
    ],
    [
      'nonboolean enabled',
      [rule('invalid-enabled', 'inbound', { enabled: 'true' })],
    ],
    [
      'over twenty rules',
      Array.from({ length: 21 }, (_, index) => rule(`too-many-${index}`)),
    ],
  ])('prevents saving %s', async (_case, rules) => {
    const wrapper = mountList(rules);

    expect(wrapper.vm.validate()).toBe(false);
    await wrapper.vm.$nextTick();
    expect(wrapper.get('[role="alert"]').text()).toBe(`${key}.ERRORS.RULES`);
  });

  it('shows server errors on the rule and for the whole list', () => {
    const wrapper = mountList([rule('in-a'), rule('in-b')], 'inbound', {
      serverErrors: {
        'in-a': { name: 'Name is taken' },
        'in-b': { action: 'Action is not allowed' },
      },
      listError: 'Too many rules',
    });

    expect(card(wrapper, 'in-a').text()).toContain('Name is taken');
    expect(card(wrapper, 'in-b').get('[role="alert"]').text()).toBe(
      'Action is not allowed'
    );
    expect(wrapper.text()).toContain('Too many rules');
  });

  it('renders every rule as one CardLayout with nothing framed inside', () => {
    const wrapper = mountList([rule('in-a'), rule('in-b')]);
    const cards = wrapper.findAllComponents(CardLayout);

    expect(cards).toHaveLength(2);
    cards.forEach(item => {
      expect(item.element.querySelectorAll('.rounded-xl')).toHaveLength(0);
    });
  });
});
