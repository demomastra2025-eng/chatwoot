// The markup of the «Модели ИИ» page as the server draws it (app/views/super_admin/app_configs/_captain.html.erb), cut
// down to what the scripts look for. The specs of the scripts build their page from these pieces.

export const TEXTS = {
  search: 'Найти модель',
  nothing_found: 'Ничего не найдено',
  changed: {
    one: 'Изменена %{count} настройка',
    few: 'Изменено %{count} настройки',
    many: 'Изменено %{count} настроек',
    other: 'Изменено %{count} настройки',
  },
  leave: 'Есть несохранённые изменения. Уйти со страницы?',
  counter: '%{count} из %{max}',
  too_many: 'Не больше 3 моделей.',
  keep_default: 'Это модель по умолчанию.',
  keep_one: 'Отметьте хотя бы одну модель.',
  default_kept:
    'Модель по умолчанию %{name} не входит в этот список — она оставлена отмеченной.',
  prompt_title: 'Правило',
  custom_group: '%{value} (своя группа)',
  custom_slot: '%{value} (своё место)',
};

export const modelSelect = ({
  key = 'CAPTAIN_IMAGE_RECOGNITION_MODEL',
  selected = '',
  extra = '',
} = {}) => `
  <div class="admin-slot" data-config="${key}">
    <label for="app_config_${key}" id="label_${key}">Распознавание картинок</label>
    <span data-unsaved-badge hidden>Не сохранено</span>
    <select name="app_config[${key}]" id="app_config_${key}" data-model-select>
      <option value="" data-name="Встроенная: GPT-6 Luna" data-kind="builtin" ${selected === '' ? 'selected' : ''}>Встроенная: GPT-6 Luna</option>
      ${extra}
      <optgroup label="Рекомендуемые">
        <option value="openai/gpt-6-luna" data-name="GPT-6 Luna" data-price="вход $1,25 / выход $10 за 1 млн" data-badges="картинки,инструменты" data-provider="OpenAI" ${selected === 'openai/gpt-6-luna' ? 'selected' : ''}>GPT-6 Luna</option>
        <option value="openai/gpt-5.6-luna" data-name="GPT-5.6 Luna" data-badges="инструменты" data-provider="OpenAI" ${selected === 'openai/gpt-5.6-luna' ? 'selected' : ''}>GPT-5.6 Luna</option>
      </optgroup>
      <optgroup label="Anthropic">
        <option value="anthropic/claude-haiku-5.5" data-name="Claude Haiku 5.5" data-price="вход $1 / выход $5 за 1 млн" data-provider="Anthropic" ${selected === 'anthropic/claude-haiku-5.5' ? 'selected' : ''}>Claude Haiku 5.5</option>
      </optgroup>
    </select>
    <button type="button" data-revert="${key}" data-revert-value="" hidden>Вернуть встроенную</button>
    <button type="button" data-revert="${key}" data-revert-value="anthropic/claude-haiku-5.5" hidden>Вернуть</button>
  </div>`;

const MODEL_NAMES = {
  'a/one': 'One',
  'b/two': 'Two',
  'c/three': 'Three',
  'd/four': 'Four',
};

export const checklist = ({
  ticked = ['a/one', 'b/two'],
  defaultId = '',
  max = 3,
} = {}) => {
  const rows = Object.keys(MODEL_NAMES)
    .map(
      id => `
      <li class="admin-checklist__row" data-row data-model-id="${id}" data-model-name="${MODEL_NAMES[id]}">
        <label class="admin-checklist__model" for="allow_${id.replace('/', '-')}">
          <input type="checkbox" name="app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]" value="${id}" id="allow_${id.replace('/', '-')}" ${ticked.includes(id) ? 'checked' : ''} data-list-check>
          <span class="admin-checklist__text"><span class="admin-checklist__name">${id}</span><span class="admin-checklist__meta"></span></span>
        </label>
        <input type="radio" name="app_config[CAPTAIN_DEFAULT_MODEL]" value="${id}" ${defaultId === id ? 'checked' : ''} data-default-radio>
      </li>`
    )
    .join('');
  return `
  <div class="admin-slot" data-config="CAPTAIN_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST" data-allowlist data-max="${max}" data-recommended='["a/one","b/two"]'>
    <span data-unsaved-badge hidden>Не сохранено</span>
    <div data-checklist>
      <input type="hidden" name="app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]" value="">
      <span class="admin-checklist__counter" data-counter>2 из 3</span>
      <ul data-checklist-rows>
        <li data-row-platform><input type="radio" name="app_config[CAPTAIN_DEFAULT_MODEL]" value="" ${defaultId === '' ? 'checked' : ''} data-default-radio></li>
        ${rows}
      </ul>
      <p data-checklist-note hidden></p>
      <select name="app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]" id="app_config_CAPTAIN_ASSISTANT_MODEL_ALLOWLIST" data-model-select data-allowlist-add>
        <option value="" data-name="Выберите модель…">Выберите модель…</option>
        <optgroup label="Прочие">
          <option value="e/five" data-name="Five" data-price="$2 за 1 млн" data-badges="картинки,инструменты">Five</option>
        </optgroup>
      </select>
      <button type="button" data-reset-recommended hidden>Вернуть рекомендуемый список</button>
    </div>
    <button type="button" data-revert="CAPTAIN_ASSISTANT_MODEL_ALLOWLIST" data-revert-value='["a/one","c/three"]' hidden>Вернуть</button>
    <button type="button" data-revert="CAPTAIN_DEFAULT_MODEL" data-revert-value="c/three" hidden>Вернуть</button>
  </div>`;
};

export const promptsBuilder = (prompts = []) => `
  <input type="hidden" name="app_config[CAPTAIN_SYSTEM_PROMPTS]" id="app_config_CAPTAIN_SYSTEM_PROMPTS" value='${JSON.stringify(prompts)}'>
  <div id="captain-system-prompts-builder" data-prompts-builder data-target-input="app_config_CAPTAIN_SYSTEM_PROMPTS" data-initial-prompts='${JSON.stringify(prompts)}'>
    <p data-role="empty" hidden>Правил пока нет.</p>
    <div data-role="rows"></div>
    <button type="button" data-role="add" hidden>Добавить правило</button>
    <template>
      <div data-role="prompt-row">
        <input type="hidden" data-field="id">
        <input type="hidden" data-field="type" value="system">
        <p data-role="title">Правило</p>
        <button type="button" data-role="remove">Удалить</button>
        <span data-role="confirm" hidden>
          <button type="button" data-role="remove-yes">Да, удалить</button>
          <button type="button" data-role="remove-no">Отмена</button>
        </span>
        <select data-field="group">
          <option value="Strict rules">Строгие правила</option>
          <option value="Conversation flow">Ход разговора</option>
        </select>
        <select data-field="slot">
          <option value="">Обычное правило</option>
          <option value="assistant_identity">Агент: кто он и что делает</option>
        </select>
        <textarea data-field="content"></textarea>
      </div>
    </template>
  </div>`;

export const page = ({ unsaved = '', body = '' } = {}) => `
  <div id="ai-models-page" data-ai-models data-texts='${JSON.stringify(TEXTS)}' data-unsaved-keys="${unsaved}">
    <div data-tablist hidden>
      <button type="button" role="tab" data-tab="connection" aria-selected="false">Подключение<span data-tab-dot hidden></span></button>
      <button type="button" role="tab" data-tab="models" aria-selected="false">Модели<span data-tab-dot hidden></span></button>
      <button type="button" role="tab" data-tab="prompts" aria-selected="false">Промпты<span data-tab-dot hidden></span></button>
    </div>
    <form id="ai-models-form" data-cancel-url="/super_admin/app_config?config=captain">
      <section data-tab-panel="connection"><input type="password" name="app_config[CAPTAIN_OPENROUTER_API_KEY]" value=""></section>
      <section data-tab-panel="models">${body}</section>
      <section data-tab-panel="prompts"></section>
      <div data-static-save><input type="submit" value="Сохранить настройки"></div>
      <div data-savebar hidden>
        <p data-savebar-text></p>
        <button type="button" data-savebar-cancel>Отменить</button>
        <input type="submit" value="Сохранить" data-savebar-save>
      </div>
    </form>
  </div>`;

export const mount = html => {
  document.body.innerHTML = html;
  return document.body;
};

export const fire = (element, type = 'change') =>
  element.dispatchEvent(new Event(type, { bubbles: true }));

export const key = (element, name) =>
  element.dispatchEvent(
    new KeyboardEvent('keydown', { key: name, bubbles: true, cancelable: true })
  );
