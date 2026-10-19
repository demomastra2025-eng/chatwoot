import { afterEach, describe, expect, it } from 'vitest';
import { initAiModelsPage } from '../ai_models';
import { initTabs } from '../ai_models/tabs';
import { checklist, fire, modelSelect, mount, page, promptsBuilder } from './aiModelsFixture';

const panelsState = () =>
  Object.fromEntries(
    Array.from(document.querySelectorAll('[data-tab-panel]')).map(panel => [panel.dataset.tabPanel, panel.hidden])
  );

describe('initTabs', () => {
  afterEach(() => {
    document.body.innerHTML = '';
    window.history.replaceState(null, '', '/');
  });

  it('does nothing on a page without tabs', () => {
    mount('<div data-ai-models></div>');

    expect(initTabs(document.querySelector('[data-ai-models]'))).toBeNull();
  });

  it('shows the buttons and the first panel only, and keeps the plain page for a page without a script', () => {
    mount(page());
    const root = document.querySelector('[data-ai-models]');
    expect(document.querySelector('[data-tablist]').hidden).toBe(true);
    expect(panelsState()).toEqual({ connection: false, models: false, prompts: false });

    initTabs(root);

    expect(document.querySelector('[data-tablist]').hidden).toBe(false);
    expect(panelsState()).toEqual({ connection: false, models: true, prompts: true });
    expect(root.classList.contains('admin-tabs-ready')).toBe(true);
    expect(Array.from(document.querySelectorAll('[role="tab"]')).map(tab => tab.getAttribute('aria-selected'))).toEqual(['true', 'false', 'false']);
  });

  it('switches the panel with a click, and remembers it in the address', () => {
    mount(page());
    initTabs(document.querySelector('[data-ai-models]'));

    document.querySelector('[data-tab="models"]').click();

    expect(panelsState()).toEqual({ connection: true, models: false, prompts: true });
    expect(window.location.hash).toBe('#models');
  });

  it('opens the tab of the address', () => {
    window.history.replaceState(null, '', '/#prompts');
    mount(page());

    initTabs(document.querySelector('[data-ai-models]'));

    expect(panelsState()).toEqual({ connection: true, models: true, prompts: false });
  });

  it('opens the tab that holds an error, first of all', () => {
    mount(page({ body: '<p data-error-for="CAPTAIN_DEFAULT_MODEL">Ошибка</p>' }));

    initTabs(document.querySelector('[data-ai-models]'));

    expect(panelsState()).toEqual({ connection: true, models: false, prompts: true });
    expect(document.querySelector('[data-tab="models"] [data-tab-dot]').hidden).toBe(false);
    expect(document.querySelector('[data-tab="models"] [data-tab-dot]').classList.contains('admin-tab__dot--error')).toBe(true);
    expect(document.querySelector('[data-tab="connection"] [data-tab-dot]').hidden).toBe(true);
  });

  it('moves between the tabs with the arrow keys', () => {
    mount(page());
    initTabs(document.querySelector('[data-ai-models]'));
    const list = document.querySelector('[data-tablist]');

    list.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true }));
    expect(panelsState().models).toBe(false);
    list.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }));
    list.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }));
    expect(panelsState().prompts).toBe(false);
  });

  it('marks the tab that has unsaved changes', () => {
    mount(page({ body: '<span data-unsaved-badge hidden></span>' }));
    const root = document.querySelector('[data-ai-models]');
    initTabs(root);

    document.querySelector('[data-unsaved-badge]').hidden = false;
    root.dispatchEvent(new CustomEvent('ai:changed'));

    expect(document.querySelector('[data-tab="models"] [data-tab-dot]').hidden).toBe(false);
    expect(document.querySelector('[data-tab="models"] [data-tab-dot]').classList.contains('admin-tab__dot--error')).toBe(false);
  });
});

describe('initAiModelsPage', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('does nothing on another page', () => {
    mount('<p>Привет</p>');

    expect(initAiModelsPage(document)).toBeNull();
  });

  it('wires the lists, the checklist, the rules, the tabs and the bar of changes together', () => {
    mount(page({ body: modelSelect() + checklist() + promptsBuilder([{ id: 'r1', type: 'system', group: 'Strict rules', content: 'Text.', slot: null }]) }));

    const result = initAiModelsPage(document);

    expect(result.page.classList.contains('is-enhanced')).toBe(true);
    expect(document.querySelectorAll('.admin-combo')).toHaveLength(2);
    expect(document.querySelectorAll('[data-role="prompt-row"]')).toHaveLength(1);
    expect(document.querySelector('[data-tablist]').hidden).toBe(false);

    const select = document.querySelector('select[data-model-select]:not([data-allowlist-add])');
    select.value = 'openai/gpt-5.6-luna';
    fire(select);
    expect(document.querySelector('[data-savebar]').hidden).toBe(false);

    document.querySelector('[data-savebar-cancel]').click();
    expect(select.value).toBe('');
    expect(document.querySelector('.admin-combo__trigger').textContent).toContain('Встроенная: GPT-6 Luna');
    expect(document.querySelector('[data-savebar]').hidden).toBe(true);
    result.settings.destroy();
  });
});
