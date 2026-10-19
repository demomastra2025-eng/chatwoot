import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  changedKeys,
  countText,
  initSettingsForm,
  settingKey,
  snapshot,
} from '../ai_models/settingsForm';
import { enhanceAll } from '../ai_models/modelPicker';
import { TEXTS, fire, modelSelect, mount, page } from './aiModelsFixture';

let running = [];

const build = ({ unsaved = '', navigate } = {}) => {
  mount(
    page({ unsaved, body: modelSelect({ selected: 'openai/gpt-6-luna' }) })
  );
  const root = document.querySelector('[data-ai-models]');
  const form = document.querySelector('form');
  const pickers = enhanceAll(root, TEXTS);
  const settings = initSettingsForm(
    root,
    form,
    TEXTS,
    navigate ? { navigate } : undefined
  );
  running.push(settings);
  return { root, form, settings, pickers };
};

describe('settingKey', () => {
  it('reads the name of a setting from the name of a control', () => {
    expect(settingKey('app_config[CAPTAIN_DEFAULT_MODEL]')).toBe(
      'CAPTAIN_DEFAULT_MODEL'
    );
    expect(settingKey('app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]')).toBe(
      'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'
    );
    expect(settingKey('confirm_embedding_change')).toBeNull();
    expect(settingKey(undefined)).toBeNull();
  });
});

describe('snapshot and changedKeys', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('takes the value of every setting, a list as its sorted items without the empty tick', () => {
    mount(`<form>
      <input name="app_config[A]" value="1">
      <input type="hidden" name="app_config[L][]" value="">
      <input type="checkbox" name="app_config[L][]" value="z" checked>
      <input type="checkbox" name="app_config[L][]" value="b" checked>
      <input type="checkbox" name="app_config[L][]" value="c">
      <input name="other" value="x">
    </form>`);

    expect(snapshot(document.querySelector('form'))).toEqual({
      A: '1',
      L: 'b\u0000z',
    });
  });

  it('names the settings whose value is not the first one, and the ones the server refused', () => {
    expect(changedKeys({ A: '1', B: '2' }, { A: '1', B: '3', C: 'x' })).toEqual(
      ['B', 'C']
    );
    expect(changedKeys({ A: '1' }, { A: '' })).toEqual(['A']);
    expect(changedKeys({ A: '1' }, { A: '1' }, ['Z'])).toEqual(['Z']);
    expect(changedKeys({ A: '' }, {})).toEqual([]);
  });
});

describe('countText', () => {
  it('writes the number of settings with the Russian form of the word', () => {
    expect(countText(TEXTS, 1)).toBe('Изменена 1 настройка');
    expect(countText(TEXTS, 2)).toBe('Изменено 2 настройки');
    expect(countText(TEXTS, 5)).toBe('Изменено 5 настроек');
    expect(countText(TEXTS, 11)).toBe('Изменено 11 настроек');
    expect(countText(TEXTS, 21)).toBe('Изменена 21 настройка');
    expect(countText(TEXTS, 24)).toBe('Изменено 24 настройки');
  });
});

describe('initSettingsForm', () => {
  afterEach(() => {
    running.forEach(settings => settings.destroy());
    running = [];
    document.body.innerHTML = '';
  });

  it('shows the buttons «Вернуть», which are hidden in the page the server draws', () => {
    mount(page({ body: modelSelect({ selected: 'openai/gpt-6-luna' }) }));
    const buttons = Array.from(document.querySelectorAll('[data-revert]'));
    expect(buttons.every(button => button.hidden)).toBe(true);

    build();

    expect(Array.from(document.querySelectorAll('[data-revert]')).every(button => !button.hidden)).toBe(true);
  });

  it('shows no bar while nothing is changed', () => {
    const { settings } = build();

    expect(document.querySelector('[data-savebar]').hidden).toBe(true);
    expect(settings.dirty()).toEqual([]);
  });

  it('shows the bar with the number of changed settings, and the mark on the card, when a model is chosen', () => {
    build();
    const select = document.querySelector('select');

    select.value = 'openai/gpt-5.6-luna';
    fire(select);

    expect(document.querySelector('[data-savebar]').hidden).toBe(false);
    expect(document.querySelector('[data-savebar-text]').textContent).toBe(
      'Изменена 1 настройка'
    );
    expect(document.querySelector('[data-unsaved-badge]').hidden).toBe(false);
  });

  it('counts a secret that is typed and takes the bar away when the value is put back', () => {
    build();
    const secret = document.querySelector('input[type="password"]');
    const select = document.querySelector('select');

    secret.value = 'sk-new';
    fire(secret, 'input');
    select.value = 'openai/gpt-5.6-luna';
    fire(select);
    expect(document.querySelector('[data-savebar-text]').textContent).toBe(
      'Изменено 2 настройки'
    );

    secret.value = '';
    fire(secret, 'input');
    select.value = 'openai/gpt-6-luna';
    fire(select);
    expect(document.querySelector('[data-savebar]').hidden).toBe(true);
    expect(document.querySelector('[data-unsaved-badge]').hidden).toBe(true);
  });

  it('puts the form back with «Отменить»', () => {
    const { pickers } = build();
    const select = document.querySelector('select');
    select.value = 'openai/gpt-5.6-luna';
    fire(select);

    document.querySelector('[data-savebar-cancel]').click();
    pickers.forEach(picker => picker.refresh());

    expect(select.value).toBe('openai/gpt-6-luna');
    expect(document.querySelector('[data-savebar]').hidden).toBe(true);
  });

  it('asks the server for the page again when «Отменить» is pressed after a refused save', () => {
    const navigate = vi.fn();
    build({ unsaved: 'CAPTAIN_IMAGE_RECOGNITION_MODEL', navigate });

    expect(document.querySelector('[data-savebar]').hidden).toBe(false);
    document.querySelector('[data-savebar-cancel]').click();

    expect(navigate).toHaveBeenCalledWith(
      '/super_admin/app_config?config=captain'
    );
  });

  it('warns before the page is left while there are changes, never after a save and never without changes', () => {
    const { form } = build();
    const leave = () => {
      const event = new Event('beforeunload', { cancelable: true });
      window.dispatchEvent(event);
      return event;
    };
    expect(leave().defaultPrevented).toBe(false);

    const select = document.querySelector('select');
    select.value = 'openai/gpt-5.6-luna';
    fire(select);
    const event = leave();
    expect(event.defaultPrevented).toBe(true);

    form.addEventListener('submit', e => e.preventDefault());
    form.dispatchEvent(new Event('submit', { cancelable: true }));
    expect(leave().defaultPrevented).toBe(false);
  });

  it('puts an earlier model into the select with the buttons «Вернуть» and «Вернуть встроенную»', () => {
    build();
    const select = document.querySelector('select');
    const [builtin, earlier] = document.querySelectorAll('[data-revert]');

    earlier.click();
    expect(select.value).toBe('anthropic/claude-haiku-5.5');
    expect(
      document.querySelector('.admin-combo__trigger').textContent
    ).toContain('Claude Haiku 5.5');
    expect(document.querySelector('[data-savebar-text]').textContent).toBe(
      'Изменена 1 настройка'
    );

    builtin.click();
    expect(select.value).toBe('');
    expect(
      document.querySelector('.admin-combo__trigger').textContent
    ).toContain('Встроенная: GPT-6 Luna');
  });

  it('can put back a model that the list was not built with', () => {
    build();
    const button = document.querySelector(
      '[data-revert-value="anthropic/claude-haiku-5.5"]'
    );
    button.dataset.revertValue = 'vendor/old';

    button.click();

    expect(document.querySelector('select').value).toBe('vendor/old');
    expect(
      document.querySelector('.admin-combo__trigger').textContent
    ).toContain('vendor/old');
  });
});
