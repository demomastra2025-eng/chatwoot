import { afterEach, describe, expect, it } from 'vitest';
import { initAllowlist, parseList } from '../ai_models/allowlist';
import { enhanceAll } from '../ai_models/modelPicker';
import { initSettingsForm } from '../ai_models/settingsForm';
import { TEXTS, checklist, fire, mount, page } from './aiModelsFixture';

let running = [];

const build = options => {
  mount(page({ body: checklist(options) }));
  const root = document.querySelector('[data-ai-models]');
  enhanceAll(root, TEXTS);
  const allowlist = initAllowlist(
    root.querySelector('[data-allowlist]'),
    TEXTS
  );
  const settings = initSettingsForm(
    root,
    document.querySelector('form'),
    TEXTS
  );
  running.push(settings);
  return { root, allowlist, settings };
};

const row = id => document.querySelector(`[data-model-id="${id}"]`);
const check = id => row(id).querySelector('[data-list-check]');
const radio = id => row(id).querySelector('[data-default-radio]');
const platform = () =>
  document.querySelector('[data-row-platform] [data-default-radio]');
const counter = () => document.querySelector('[data-counter]').textContent;
const note = () => document.querySelector('[data-checklist-note]');
const tick = (id, value) => {
  check(id).checked = value;
  fire(check(id));
};

describe('parseList', () => {
  it('reads a JSON list of models, and nothing from anything else', () => {
    expect(parseList('["a","b"]')).toEqual(['a', 'b']);
    expect(parseList('')).toEqual([]);
    expect(parseList('{broken')).toEqual([]);
    expect(parseList('{"a":1}')).toEqual([]);
  });
});

describe('initAllowlist', () => {
  afterEach(() => {
    running.forEach(settings => settings.destroy());
    running = [];
    document.body.innerHTML = '';
  });

  it('counts the ticked models, «2 из 3»', () => {
    build();

    expect(counter()).toBe('2 из 3');
    tick('c/three', true);
    expect(counter()).toBe('3 из 3');
    tick('c/three', false);
    expect(counter()).toBe('2 из 3');
  });

  it('refuses a tick over the limit and says why', () => {
    build({ ticked: ['a/one', 'b/two', 'c/three'] });

    tick('d/four', true);

    expect(check('d/four').checked).toBe(false);
    expect(counter()).toBe('3 из 3');
    expect(note().hidden).toBe(false);
    expect(note().textContent).toBe('Не больше 3 моделей.');
  });

  it('turns off the default radio of a model that is not ticked, and on again when it is ticked', () => {
    build();

    expect(radio('c/three').disabled).toBe(true);
    expect(radio('a/one').disabled).toBe(false);
    expect(platform().disabled).toBe(false);
    tick('c/three', true);
    expect(radio('c/three').disabled).toBe(false);
  });

  it('does not let the default model be unticked, and says what to do first', () => {
    build({ defaultId: 'a/one' });

    tick('a/one', false);

    expect(check('a/one').checked).toBe(true);
    expect(note().textContent).toBe('Это модель по умолчанию.');
    radio('b/two').checked = true;
    fire(radio('b/two'));
    tick('a/one', false);
    expect(check('a/one').checked).toBe(false);
    expect(note().hidden).toBe(true);
  });

  it('keeps a default model that was sent and refused, even when its row is not ticked', () => {
    build({ ticked: ['a/one'], defaultId: 'c/three' });

    expect(radio('c/three').checked).toBe(true);
    expect(radio('c/three').disabled).toBe(false);
  });

  it('adds a ticked row for a model chosen in «Добавить другую модель», and the list goes back to its first option', () => {
    build();
    const add = document.querySelector('select[data-allowlist-add]');

    add.value = 'e/five';
    fire(add);

    const added = row('e/five');
    expect(added).toBeTruthy();
    expect(added.querySelector('[data-list-check]').checked).toBe(true);
    expect(added.querySelector('[data-list-check]').name).toBe(
      'app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]'
    );
    expect(added.querySelector('[data-default-radio]').name).toBe(
      'app_config[CAPTAIN_DEFAULT_MODEL]'
    );
    expect(added.textContent).toContain('Five');
    expect(added.textContent).toContain('$2 за 1 млн');
    expect(add.value).toBe('');
    expect(counter()).toBe('3 из 3');
  });

  it('adds a model to the list and makes it the default in one go, and the form sees both', () => {
    const { settings } = build();
    const add = document.querySelector('select[data-allowlist-add]');
    add.value = 'e/five';
    fire(add);

    radio('e/five').checked = true;
    fire(radio('e/five'));

    expect(settings.dirty().sort()).toEqual([
      'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST',
      'CAPTAIN_DEFAULT_MODEL',
    ]);
    expect(document.querySelector('[data-savebar-text]').textContent).toBe(
      'Изменено 2 настройки'
    );
    expect(document.querySelector('[data-unsaved-badge]').hidden).toBe(false);
  });

  it('does not add a model over the limit', () => {
    build({ ticked: ['a/one', 'b/two', 'c/three'] });
    const add = document.querySelector('select[data-allowlist-add]');

    add.value = 'e/five';
    fire(add);

    expect(row('e/five')).toBeNull();
    expect(note().textContent).toBe('Не больше 3 моделей.');
  });

  it('ticks the recommended models and nothing else with «Вернуть рекомендуемый список»', () => {
    build({ ticked: ['b/two', 'c/three', 'd/four'] });
    const reset = document.querySelector('[data-reset-recommended]');
    expect(reset.hidden).toBe(false);

    reset.click();

    expect(
      ['a/one', 'b/two', 'c/three', 'd/four'].map(id => check(id).checked)
    ).toEqual([true, true, false, false]);
    expect(platform().checked).toBe(true);
    expect(note().hidden).toBe(true);
    expect(counter()).toBe('2 из 3');
  });

  it('does not take the default model away with «Вернуть рекомендуемый список»: its row stays ticked and a line says so', () => {
    build({ ticked: ['b/two', 'c/three', 'd/four'], defaultId: 'c/three' });

    document.querySelector('[data-reset-recommended]').click();

    expect(
      ['a/one', 'b/two', 'c/three', 'd/four'].map(id => check(id).checked)
    ).toEqual([true, true, true, false]);
    // the default model is as it was: it is neither the platform's nor another one
    expect(radio('c/three').checked).toBe(true);
    expect(platform().checked).toBe(false);
    expect(counter()).toBe('3 из 3');
    expect(note().hidden).toBe(false);
    expect(note().textContent).toBe(
      'Модель по умолчанию Three не входит в этот список — она оставлена отмеченной.'
    );
  });

  it('says that the list is over the limit when the default model that stays makes it so', () => {
    build({ ticked: ['c/three'], defaultId: 'c/three', max: 2 });

    document.querySelector('[data-reset-recommended]').click();

    expect(check('c/three').checked).toBe(true);
    expect(counter()).toBe('3 из 2');
    expect(document.querySelector('[data-counter]').className).toContain(
      'is-over'
    );
    expect(note().textContent).toContain('Модель по умолчанию Three');
    expect(note().textContent).toContain('Не больше 3 моделей.');
  });

  it('refuses to untick the last model', () => {
    build({ ticked: ['a/one'] });

    tick('a/one', false);

    expect(check('a/one').checked).toBe(true);
    expect(counter()).toBe('1 из 3');
    expect(note().textContent).toBe('Отметьте хотя бы одну модель.');
  });

  it('puts an earlier short list back, adding the rows it needs', () => {
    build({ ticked: ['b/two', 'd/four'] });
    const button = document.querySelector(
      '[data-revert="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST"]'
    );
    button.dataset.revertValue = '["a/one","x/new"]';

    button.click();

    expect(['a/one', 'b/two', 'd/four'].map(id => check(id).checked)).toEqual([
      true,
      false,
      false,
    ]);
    expect(check('x/new').checked).toBe(true);
    expect(counter()).toBe('2 из 3');
  });

  it('keeps the default model when an earlier short list leaves it out', () => {
    build({ ticked: ['b/two', 'd/four'], defaultId: 'd/four' });
    const button = document.querySelector(
      '[data-revert="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST"]'
    );
    button.dataset.revertValue = '["a/one","b/two"]';

    button.click();

    expect(
      ['a/one', 'b/two', 'c/three', 'd/four'].map(id => check(id).checked)
    ).toEqual([true, true, false, true]);
    expect(radio('d/four').checked).toBe(true);
    expect(platform().checked).toBe(false);
    expect(note().textContent).toContain('Модель по умолчанию Four');
  });

  it('reads an earlier blank short list as «the recommended list», not as a list of nothing', () => {
    const { settings } = build({
      ticked: ['b/two', 'd/four'],
      defaultId: 'd/four',
    });
    const button = document.querySelector(
      '[data-revert="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST"]'
    );
    button.dataset.revertValue = '';

    button.click();

    expect(
      ['a/one', 'b/two', 'c/three', 'd/four'].map(id => check(id).checked)
    ).toEqual([true, true, false, true]);
    expect(counter()).toBe('3 из 3');
    // the model by default did not move to «Как у платформы»
    expect(radio('d/four').checked).toBe(true);
    expect(platform().checked).toBe(false);
    // only the list changed: one setting, not two
    expect(settings.dirty()).toEqual(['CAPTAIN_ASSISTANT_MODEL_ALLOWLIST']);
    expect(document.querySelector('[data-savebar-text]').textContent).toBe(
      'Изменена 1 настройка'
    );
  });

  it('reads an earlier list of nothing, "[]", as the recommended list too', () => {
    build({ ticked: ['c/three', 'd/four'] });
    const button = document.querySelector(
      '[data-revert="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST"]'
    );
    button.dataset.revertValue = '[]';

    button.click();

    expect(
      ['a/one', 'b/two', 'c/three', 'd/four'].map(id => check(id).checked)
    ).toEqual([true, true, false, false]);
  });

  it('puts an earlier default model back, ticking its row', () => {
    build({ defaultId: 'a/one' });
    const button = document.querySelector(
      '[data-revert="CAPTAIN_DEFAULT_MODEL"]'
    );

    button.click();

    expect(radio('c/three').checked).toBe(true);
    expect(check('c/three').checked).toBe(true);
  });

  it('forgets the rows it added when the form is reset', () => {
    const { root } = build();
    const add = document.querySelector('select[data-allowlist-add]');
    add.value = 'e/five';
    fire(add);
    expect(row('e/five')).toBeTruthy();

    document.querySelector('form').reset();
    root.dispatchEvent(new CustomEvent('ai:reset'));

    expect(row('e/five')).toBeNull();
    expect(counter()).toBe('2 из 3');
  });
});
