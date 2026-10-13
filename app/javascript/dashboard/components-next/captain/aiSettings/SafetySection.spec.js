import { afterEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import Select from 'dashboard/components-next/select/Select.vue';
import SafetySection from './SafetySection.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

const SAFETY = 'CAPTAIN.AI_SETTINGS.SAFETY';
const FORM = 'CAPTAIN.ASSISTANTS.FORM';

const rule = (id, direction = 'inbound', changes = {}) => ({
  id,
  name: `Rule ${id}`,
  direction,
  instruction: 'If the customer asks to change contract terms.',
  action: 'handoff',
  enabled: true,
  message: '',
  ...changes,
});

const safety = (changes = {}) => ({
  moderation_enabled: false,
  prompt_injection_action: 'block',
  sensitive_info_action: 'block',
  custom_rules: [],
  ...changes,
});

const mountSection = (value = safety(), props = {}) => {
  let wrapper = null;
  wrapper = mount(SafetySection, {
    props: {
      modelValue: value,
      'onUpdate:modelValue': next => wrapper.setProps({ modelValue: next }),
      ...props,
    },
  });
  return wrapper;
};
const draft = wrapper => wrapper.props('modelValue');
const optionValues = (wrapper, id) =>
  wrapper
    .get(`#${id}`)
    .findAll('option')
    .map(option => option.element.value);

describe('SafetySection', () => {
  afterEach(() => vi.restoreAllMocks());

  it('offers the standard checks and one rule list for each direction', () => {
    const wrapper = mountSection();
    const standard = wrapper.get('[data-testid="safety-standard"]');

    expect(wrapper.text()).toContain(`${SAFETY}.STANDARD`);
    expect(wrapper.text()).toContain(`${FORM}.SAFETY_SETTINGS.DESCRIPTION`);
    expect(standard.text()).toContain(`${SAFETY}.MODERATION`);
    expect(standard.text()).toContain(`${SAFETY}.INJECTION`);
    expect(standard.text()).toContain(`${SAFETY}.SENSITIVE`);
    expect(standard.findAll('[role="switch"]')).toHaveLength(1);
    ['prompt_injection_action', 'sensitive_info_action'].forEach(field => {
      expect(optionValues(wrapper, `ai-settings-${field}`)).toEqual([
        'block',
        'flag',
        'off',
      ]);
    });
    expect(
      wrapper
        .get('#ai-settings-sensitive_info_action')
        .findAll('option')
        .map(option => option.text())
    ).toEqual([
      `${FORM}.SAFETY_SETTINGS.BLOCK`,
      `${FORM}.SAFETY_SETTINGS.FLAG`,
      `${SAFETY}.OFF`,
    ]);

    const inbound = wrapper.get('[data-testid="custom-rules-inbound"]');
    const outbound = wrapper.get('[data-testid="custom-rules-outbound"]');
    expect(inbound.text()).toContain(`${SAFETY}.INBOUND`);
    expect(inbound.text()).toContain(
      `${FORM}.CUSTOM_GUARDRAILS.INPUT.DESCRIPTION`
    );
    expect(outbound.text()).toContain(`${SAFETY}.OUTBOUND`);
    expect(outbound.text()).toContain(
      `${FORM}.CUSTOM_GUARDRAILS.OUTPUT.DESCRIPTION`
    );
    expect(inbound.text()).toContain(`${SAFETY}.ADD_RULE`);
    expect(outbound.text()).toContain(`${SAFETY}.ADD_RULE`);
  });

  it('shows the values of the model in the switch and both selects', () => {
    const wrapper = mountSection(
      safety({
        moderation_enabled: true,
        prompt_injection_action: 'flag',
        sensitive_info_action: 'off',
      })
    );

    expect(
      wrapper
        .get('[data-testid="safety-moderation"]')
        .attributes('aria-checked')
    ).toBe('true');
    expect(
      wrapper.get('#ai-settings-prompt_injection_action').element.value
    ).toBe('flag');
    expect(
      wrapper.get('#ai-settings-sensitive_info_action').element.value
    ).toBe('off');
  });

  it('turns content moderation on and off and keeps every other value', async () => {
    const rules = [rule('in-1')];
    const wrapper = mountSection(
      safety({ prompt_injection_action: 'flag', custom_rules: rules })
    );

    await wrapper.get('[data-testid="safety-moderation"]').trigger('click');
    expect(draft(wrapper)).toEqual(
      safety({
        moderation_enabled: true,
        prompt_injection_action: 'flag',
        custom_rules: rules,
      })
    );

    await wrapper.get('[data-testid="safety-moderation"]').trigger('click');
    expect(draft(wrapper).moderation_enabled).toBe(false);
  });

  it('sets the instruction and credentials actions one at a time', async () => {
    const wrapper = mountSection();

    await wrapper.get('#ai-settings-prompt_injection_action').setValue('flag');
    await wrapper.get('#ai-settings-sensitive_info_action').setValue('off');

    expect(draft(wrapper)).toEqual(
      safety({ prompt_injection_action: 'flag', sensitive_info_action: 'off' })
    );
  });

  it('ignores a value that is not a safety action', async () => {
    const wrapper = mountSection();
    const [injection] = wrapper.findAllComponents(Select);

    injection.vm.$emit('update:modelValue', 'allow-everything');
    await wrapper.vm.$nextTick();

    expect(draft(wrapper).prompt_injection_action).toBe('block');
  });

  it('adds a rule of the list direction to the one shared rule list', async () => {
    vi.spyOn(window.crypto, 'randomUUID')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000001')
      .mockReturnValueOnce('00000000-0000-4000-8000-000000000002');
    const wrapper = mountSection();

    await wrapper
      .get('[data-testid="custom-rule-add-outbound"]')
      .trigger('click');
    await wrapper
      .get('[data-testid="custom-rule-add-inbound"]')
      .trigger('click');

    expect(draft(wrapper).custom_rules.map(item => item.direction)).toEqual([
      'outbound',
      'inbound',
    ]);
    expect(
      wrapper
        .get('[data-testid="custom-rules-inbound"]')
        .findAll('li')
        .map(item => item.attributes('data-testid'))
    ).toEqual(['custom-rule-00000000-0000-4000-8000-000000000002']);
    expect(
      wrapper
        .get('[data-testid="custom-rules-outbound"]')
        .findAll('li')
        .map(item => item.attributes('data-testid'))
    ).toEqual(['custom-rule-00000000-0000-4000-8000-000000000001']);
  });

  it('shows the field errors, the list error and the error of a single rule', () => {
    const wrapper = mountSection(
      safety({ custom_rules: [rule('in-1'), rule('out-1', 'outbound')] }),
      {
        errors: {
          moderation_enabled: 'Moderation is not a boolean',
          prompt_injection_action: 'Injection action is unknown',
          sensitive_info_action: 'Credentials action is unknown',
          custom_rules: 'Too many rules',
        },
        ruleErrors: { 'out-1': { name: 'Name is taken' } },
      }
    );

    const text = wrapper.text();
    expect(text).toContain('Moderation is not a boolean');
    expect(text).toContain('Injection action is unknown');
    expect(text).toContain('Credentials action is unknown');
    expect(
      wrapper.get('[data-testid="custom-rules-inbound"]').text()
    ).toContain('Too many rules');
    expect(wrapper.get('[data-testid="custom-rule-out-1"]').text()).toContain(
      'Name is taken'
    );
    expect(
      wrapper.get('[data-testid="custom-rule-in-1"]').text()
    ).not.toContain('Name is taken');
  });

  it('locks every control while the page is saving', () => {
    const wrapper = mountSection(safety({ custom_rules: [rule('in-1')] }), {
      disabled: true,
    });

    expect(
      wrapper.get('[data-testid="safety-moderation"]').attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper.get('#ai-settings-prompt_injection_action').attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper.get('#ai-settings-sensitive_info_action').attributes('disabled')
    ).toBeDefined();
    ['inbound', 'outbound'].forEach(direction => {
      expect(
        wrapper
          .get(`[data-testid="custom-rule-add-${direction}"]`)
          .attributes('disabled')
      ).toBeDefined();
    });
    expect(
      wrapper.get('#custom-rule-in-1-name').attributes('disabled')
    ).toBeDefined();
  });
});
