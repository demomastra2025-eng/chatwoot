import { afterEach, describe, expect, it } from 'vitest';
import {
  initPromptsBuilder,
  serializePrompts,
} from '../ai_models/promptsBuilder';
import { TEXTS, fire, mount, promptsBuilder } from './aiModelsFixture';

const RULES = [
  {
    id: 'r1',
    type: 'system',
    group: 'Strict rules',
    content: 'Stay in scope.',
    slot: null,
  },
  {
    id: 'r2',
    type: 'system',
    group: 'Conversation flow',
    content: 'Be brief.',
    slot: 'assistant_identity',
  },
];

const build = (prompts = RULES) => {
  mount(`<form>${promptsBuilder(prompts)}</form>`);
  const builder = document.querySelector('[data-prompts-builder]');
  const api = initPromptsBuilder(builder, TEXTS);
  const hidden = document.getElementById('app_config_CAPTAIN_SYSTEM_PROMPTS');
  return { builder, api, hidden };
};

const rows = () =>
  Array.from(document.querySelectorAll('[data-role="prompt-row"]'));
const field = (row, name) => row.querySelector(`[data-field="${name}"]`);
const saved = hidden => JSON.parse(hidden.value);

describe('initPromptsBuilder', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('draws a row for every saved rule, with its group and place chosen in the lists', () => {
    build();

    expect(rows()).toHaveLength(2);
    expect(field(rows()[0], 'group').value).toBe('Strict rules');
    expect(field(rows()[0], 'slot').value).toBe('');
    expect(field(rows()[1], 'group').value).toBe('Conversation flow');
    expect(field(rows()[1], 'slot').value).toBe('assistant_identity');
    expect(field(rows()[1], 'content').value).toBe('Be brief.');
    expect(
      rows().map(row => row.querySelector('[data-role="title"]').textContent)
    ).toEqual(['Правило 1', 'Правило 2']);
  });

  it('has the same rules in the field that is sent', () => {
    const { hidden } = build();

    expect(saved(hidden)).toEqual(RULES);
  });

  it("offers a group or a place that the lists do not know, as the rule's own, so that it is not lost", () => {
    const { hidden } = build([
      {
        id: 'old',
        type: 'system',
        group: 'Своя группа',
        content: 'Old rule.',
        slot: 'old_slot',
      },
    ]);
    const [row] = rows();

    expect(field(row, 'group').value).toBe('Своя группа');
    expect(
      field(row, 'group').options[field(row, 'group').selectedIndex].textContent
    ).toBe('Своя группа (своя группа)');
    expect(field(row, 'slot').value).toBe('old_slot');
    expect(
      field(row, 'slot').options[field(row, 'slot').selectedIndex].textContent
    ).toBe('old_slot (своё место)');
    expect(saved(hidden)[0]).toMatchObject({
      group: 'Своя группа',
      slot: 'old_slot',
    });
  });

  it('keeps no field of a group or a place to type into', () => {
    build();

    expect(
      document.querySelectorAll('[data-role="prompt-row"] input[type="text"]')
    ).toHaveLength(0);
  });

  it('writes a change of the text, the group and the place into the field that is sent', () => {
    const { hidden } = build();
    const [row] = rows();

    field(row, 'content').value = '  Changed.  ';
    fire(field(row, 'content'), 'input');
    field(row, 'group').value = 'Conversation flow';
    fire(field(row, 'group'));
    field(row, 'slot').value = 'assistant_identity';
    fire(field(row, 'slot'));

    expect(saved(hidden)[0]).toEqual({
      id: 'r1',
      type: 'system',
      group: 'Conversation flow',
      content: 'Changed.',
      slot: 'assistant_identity',
    });
  });

  it('adds an empty rule, which is not sent until it has text', () => {
    const { hidden } = build();
    document.querySelector('[data-role="add"]').click();

    expect(rows()).toHaveLength(3);
    expect(saved(hidden)).toHaveLength(2);
    const row = rows()[2];
    expect(field(row, 'id').value).toMatch(/^system_prompt_/);
    field(row, 'content').value = 'New rule.';
    fire(field(row, 'content'), 'input');
    expect(saved(hidden)).toHaveLength(3);
    expect(saved(hidden)[2]).toMatchObject({
      content: 'New rule.',
      group: 'Strict rules',
      slot: null,
      type: 'system',
    });
  });

  it('deletes a rule only after the question, and not when the answer is «Отмена»', () => {
    const { hidden } = build();
    const [row] = rows();
    const confirm = row.querySelector('[data-role="confirm"]');
    const remove = row.querySelector('[data-role="remove"]');

    remove.click();
    expect(confirm.hidden).toBe(false);
    expect(remove.hidden).toBe(true);
    expect(rows()).toHaveLength(2);
    expect(saved(hidden)).toHaveLength(2);

    row.querySelector('[data-role="remove-no"]').click();
    expect(confirm.hidden).toBe(true);
    expect(remove.hidden).toBe(false);
    expect(rows()).toHaveLength(2);

    remove.click();
    row.querySelector('[data-role="remove-yes"]').click();
    expect(rows()).toHaveLength(1);
    expect(saved(hidden).map(rule => rule.id)).toEqual(['r2']);
    expect(rows()[0].querySelector('[data-role="title"]').textContent).toBe(
      'Правило 1'
    );
  });

  it('tells the form when a rule is deleted', () => {
    const { hidden } = build();
    const events = [];
    hidden.addEventListener('change', () => events.push('change'));
    const [row] = rows();

    row.querySelector('[data-role="remove"]').click();
    row.querySelector('[data-role="remove-yes"]').click();

    expect(events).toEqual(['change']);
  });

  it('drops a rule without text at once, without a question', () => {
    const { hidden } = build();
    document.querySelector('[data-role="add"]').click();

    const [, , fresh] = rows();
    fresh.querySelector('[data-role="remove"]').click();

    expect(rows()).toHaveLength(2);
    expect(saved(hidden)).toHaveLength(2);
  });

  it('says there are no rules when there are none, and shows the button to add one', () => {
    build([]);

    expect(document.querySelector('[data-role="empty"]').hidden).toBe(false);
    expect(document.querySelector('[data-role="add"]').hidden).toBe(false);
  });

  it('reads rules that are damaged as no rules', () => {
    mount(
      `<form><input type="hidden" id="app_config_CAPTAIN_SYSTEM_PROMPTS" value="{broken"><div data-prompts-builder data-target-input="app_config_CAPTAIN_SYSTEM_PROMPTS" data-initial-prompts="{broken"><div data-role="rows"></div><template><div data-role="prompt-row"></div></template></div></form>`
    );

    expect(() =>
      initPromptsBuilder(
        document.querySelector('[data-prompts-builder]'),
        TEXTS
      )
    ).not.toThrow();
    expect(rows()).toHaveLength(0);
  });
});

describe('serializePrompts', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('writes the rows as the rules that are stored, leaving out a rule without text', () => {
    build();
    document.querySelector('[data-role="add"]').click();

    expect(JSON.parse(serializePrompts(rows()))).toEqual(RULES);
  });
});
