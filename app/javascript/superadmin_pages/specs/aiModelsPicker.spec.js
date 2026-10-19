import { afterEach, describe, expect, it } from 'vitest';
import {
  enhanceModelSelect,
  matchesQuery,
  readEntries,
} from '../ai_models/modelPicker';
import { TEXTS, fire, key, modelSelect, mount } from './aiModelsFixture';

const setup = options => {
  mount(modelSelect(options));
  const select = document.querySelector('select');
  const picker = enhanceModelSelect(select, TEXTS);
  return { select, picker };
};

const search = value => {
  const input = document.querySelector('.admin-combo__search');
  input.value = value;
  fire(input, 'input');
  return input;
};

const visibleOptions = () =>
  Array.from(
    document.querySelectorAll('.admin-combo__option:not([hidden])')
  ).map(node => node.dataset.value);

describe('matchesQuery', () => {
  it('finds a text that holds every word of the query, in any case and order', () => {
    expect(matchesQuery('OpenAI GPT-6 Luna', 'luna gpt')).toBe(true);
    expect(matchesQuery('OpenAI GPT-6 Luna', 'claude')).toBe(false);
    expect(matchesQuery('anything', '')).toBe(true);
    expect(matchesQuery('anything', '   ')).toBe(true);
  });
});

describe('readEntries', () => {
  it('reads the groups and the options of a select with what the server put in them', () => {
    mount(modelSelect({ selected: 'openai/gpt-6-luna' }));
    const entries = readEntries(document.querySelector('select'));

    expect(entries.map(entry => entry.type)).toEqual([
      'option',
      'group',
      'option',
      'option',
      'group',
      'option',
    ]);
    expect(entries[2]).toMatchObject({
      value: 'openai/gpt-6-luna',
      name: 'GPT-6 Luna',
      price: 'вход $1,25 / выход $10 за 1 млн',
      badges: ['картинки', 'инструменты'],
      provider: 'OpenAI',
      group: 'Рекомендуемые',
    });
    expect(entries[0]).toMatchObject({ value: '', kind: 'builtin' });
  });
});

describe('enhanceModelSelect', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('hides the select, keeps it in the form, and shows the chosen model on a button', () => {
    const { select } = setup({ selected: 'openai/gpt-6-luna' });
    const trigger = document.querySelector('.admin-combo__trigger');

    expect(select.hidden).toBe(true);
    expect(select.closest('form, div')).toBeTruthy();
    expect(trigger.textContent).toContain('GPT-6 Luna');
    expect(trigger.textContent).toContain('вход $1,25 / выход $10 за 1 млн');
    expect(trigger.textContent).toContain('картинки');
    expect(trigger.getAttribute('aria-expanded')).toBe('false');
  });

  it('does not do it twice', () => {
    const { select } = setup();

    expect(enhanceModelSelect(select, TEXTS)).toBeNull();
    expect(document.querySelectorAll('.admin-combo')).toHaveLength(1);
  });

  it('points the label of the select at the button', () => {
    setup();
    const trigger = document.querySelector('.admin-combo__trigger');

    expect(document.querySelector('label').getAttribute('for')).toBe(
      trigger.id
    );
    expect(trigger.getAttribute('aria-labelledby')).toContain(
      'label_CAPTAIN_IMAGE_RECOGNITION_MODEL'
    );
  });

  it('opens a panel with every model under its group, and closes it on a second click', () => {
    setup();
    const trigger = document.querySelector('.admin-combo__trigger');
    const panel = document.querySelector('.admin-combo__panel');

    expect(panel.hidden).toBe(true);
    trigger.click();
    expect(panel.hidden).toBe(false);
    expect(trigger.getAttribute('aria-expanded')).toBe('true');
    expect(visibleOptions()).toEqual([
      '',
      'openai/gpt-6-luna',
      'openai/gpt-5.6-luna',
      'anthropic/claude-haiku-5.5',
    ]);
    expect(
      Array.from(document.querySelectorAll('.admin-combo__group')).map(
        node => node.textContent
      )
    ).toEqual(['Рекомендуемые', 'Anthropic']);
    trigger.click();
    expect(panel.hidden).toBe(true);
  });

  it('searches by the name, the id and the company, and hides the title of a group that has nothing left', () => {
    setup();
    document.querySelector('.admin-combo__trigger').click();

    search('claude');
    expect(visibleOptions()).toEqual(['anthropic/claude-haiku-5.5']);
    const groups = Array.from(document.querySelectorAll('.admin-combo__group'));
    expect(groups.map(node => node.hidden)).toEqual([true, false]);

    search('openai luna');
    expect(visibleOptions()).toEqual([
      'openai/gpt-6-luna',
      'openai/gpt-5.6-luna',
    ]);
    expect(groups.map(node => node.hidden)).toEqual([false, true]);

    search('zzz');
    expect(visibleOptions()).toEqual([]);
    expect(document.querySelector('.admin-combo__empty').hidden).toBe(false);
    expect(document.querySelector('.admin-combo__empty').textContent).toBe(
      'Ничего не найдено'
    );
  });

  it('writes the chosen model into the select and tells the form', () => {
    const { select } = setup();
    const seen = [];
    select.addEventListener('change', () => seen.push(select.value));
    document.querySelector('.admin-combo__trigger').click();

    document.querySelector('[data-value="anthropic/claude-haiku-5.5"]').click();

    expect(select.value).toBe('anthropic/claude-haiku-5.5');
    expect(seen).toContain('anthropic/claude-haiku-5.5');
    expect(
      document.querySelector('.admin-combo__trigger').textContent
    ).toContain('Claude Haiku 5.5');
    expect(document.querySelector('.admin-combo__panel').hidden).toBe(true);
  });

  it('is used from the keyboard: arrows move, Enter chooses, Escape closes', () => {
    const { select } = setup();
    const trigger = document.querySelector('.admin-combo__trigger');
    key(trigger, 'ArrowDown');
    const input = document.querySelector('.admin-combo__search');
    expect(document.querySelector('.admin-combo__panel').hidden).toBe(false);

    key(input, 'ArrowDown');
    key(input, 'ArrowDown');
    key(input, 'Enter');
    expect(select.value).toBe('openai/gpt-5.6-luna');

    key(trigger, 'ArrowDown');
    key(document.querySelector('.admin-combo__search'), 'Escape');
    expect(document.querySelector('.admin-combo__panel').hidden).toBe(true);
    expect(select.value).toBe('openai/gpt-5.6-luna');
  });

  it('closes when the page is clicked elsewhere', () => {
    setup();
    document.querySelector('.admin-combo__trigger').click();

    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));

    expect(document.querySelector('.admin-combo__panel').hidden).toBe(true);
  });

  it('keeps a saved model that the list does not offer selected and marked', () => {
    const extra = `<optgroup label="Сохранённая модель"><option value="vendor/gone" data-name="vendor/gone" data-note="нет в каталоге" selected>vendor/gone · нет в каталоге</option></optgroup>`;
    const { select } = setup({ selected: 'vendor/gone', extra });
    const trigger = document.querySelector('.admin-combo__trigger');

    expect(select.value).toBe('vendor/gone');
    expect(trigger.textContent).toContain('vendor/gone');
    expect(trigger.textContent).toContain('нет в каталоге');
  });

  it('follows a value that is put into the select from outside (the buttons «Вернуть»)', () => {
    const { select } = setup();

    select.value = 'openai/gpt-5.6-luna';
    fire(select);

    expect(
      document.querySelector('.admin-combo__trigger').textContent
    ).toContain('GPT-5.6 Luna');
  });

  it('shows the text of an option that it was not built with', () => {
    const { select, picker } = setup();
    const option = document.createElement('option');
    option.value = 'vendor/new';
    option.textContent = 'vendor/new';
    select.appendChild(option);

    select.value = 'vendor/new';
    picker.refresh();

    expect(
      document.querySelector('.admin-combo__trigger').textContent
    ).toContain('vendor/new');
  });
});
