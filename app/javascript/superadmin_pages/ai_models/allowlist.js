// The short list of models and the model by default (the card «Основная модель агентов»).
//
// The server renders the list as checkboxes (`app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]`) and the default model as
// radios (`app_config[CAPTAIN_DEFAULT_MODEL]`) in the same rows, and both work without a script. With a script:
//  * the counter «5 из 12» follows the ticks and the 13th tick is refused;
//  * the radio of a row that is not ticked is off: the default model has to be on the list;
//  * the default model cannot be unticked while it is the default;
//  * the select «Добавить другую модель» adds a ticked row;
//  * «Вернуть рекомендуемый список» ticks the recommended models and nothing else.

import { RESET_EVENT, SET_VALUE_EVENT } from './settingsForm';

const LIST_KEY = 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST';
const DEFAULT_KEY = 'CAPTAIN_DEFAULT_MODEL';

export const parseList = text => {
  try {
    const parsed = JSON.parse(text || '[]');
    return Array.isArray(parsed) ? parsed.map(String).filter(Boolean) : [];
  } catch (error) {
    return [];
  }
};

export const initAllowlist = (card, texts = {}) => {
  if (!card) return null;
  const doc = card.ownerDocument;
  const rowsBox = card.querySelector('[data-checklist-rows]');
  const counter = card.querySelector('[data-counter]');
  const note = card.querySelector('[data-checklist-note]');
  const addSelect = card.querySelector('[data-allowlist-add]');
  const resetButton = card.querySelector('[data-reset-recommended]');
  const max = Number(card.dataset.max) || 12;
  const recommended = parseList(card.dataset.recommended);
  const listName = `app_config[${LIST_KEY}][]`;
  const defaultName = `app_config[${DEFAULT_KEY}]`;

  const rows = () => Array.from(rowsBox.querySelectorAll('[data-row]'));
  const checkOf = row => row.querySelector('[data-list-check]');
  const radioOf = row => row.querySelector('[data-default-radio]');
  const platformRadio = () => rowsBox.querySelector('[data-row-platform] [data-default-radio]');
  const checkedRows = () => rows().filter(row => checkOf(row).checked);
  const defaultRadio = () =>
    rowsBox.querySelector('[data-default-radio]:checked') || platformRadio();

  const say = message => {
    if (!note) return;
    note.textContent = message || '';
    note.hidden = !message;
  };

  const sync = () => {
    const count = checkedRows().length;
    if (counter) {
      counter.textContent = (texts.counter || '%{count} / %{max}')
        .replace('%{count}', String(count))
        .replace('%{max}', String(max));
      counter.classList.toggle('is-over', count > max);
    }
    rows().forEach(row => {
      const ticked = checkOf(row).checked;
      // the radio the server drew as chosen stays on even when its row is not ticked: it is what the admin entered
      radioOf(row).disabled = !ticked && !radioOf(row).checked;
      if (ticked) row.removeAttribute('data-disabled');
      else row.setAttribute('data-disabled', 'true');
    });
  };

  const fire = element => {
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
  };

  const buildRow = ({ id, name, meta, note: rowNote }) => {
    const slug = id.replace(/[^a-z0-9]+/gi, '-');
    const li = doc.createElement('li');
    li.className = 'admin-checklist__row';
    li.dataset.row = '';
    li.dataset.modelId = id;
    li.dataset.added = 'true';

    const label = doc.createElement('label');
    label.className = 'admin-checklist__model';
    label.htmlFor = `allow_${slug}`;
    const check = doc.createElement('input');
    check.type = 'checkbox';
    check.name = listName;
    check.value = id;
    check.id = `allow_${slug}`;
    check.checked = true;
    check.setAttribute('data-list-check', '');
    const text = doc.createElement('span');
    text.className = 'admin-checklist__text';
    const nameNode = doc.createElement('span');
    nameNode.className = 'admin-checklist__name';
    nameNode.textContent = name;
    if (rowNote) {
      const badge = doc.createElement('span');
      badge.className = 'admin-badge admin-badge--amber';
      badge.textContent = rowNote;
      nameNode.append(' ', badge);
    }
    const metaNode = doc.createElement('span');
    metaNode.className = 'admin-checklist__meta';
    metaNode.textContent = meta || '';
    text.append(nameNode, metaNode);
    label.append(check, text);

    const radio = doc.createElement('input');
    radio.type = 'radio';
    radio.name = defaultName;
    radio.value = id;
    radio.setAttribute('data-default-radio', '');
    radio.setAttribute('aria-label', name);
    li.append(label, radio);
    rowsBox.appendChild(li);
    return li;
  };

  const rowFor = id => rows().find(row => row.dataset.modelId === id);

  const tick = id => {
    const row = rowFor(id) || buildRow({ id, name: id });
    checkOf(row).checked = true;
    return row;
  };

  rowsBox.addEventListener('change', event => {
    const { target } = event;
    if (target.matches('[data-list-check]')) {
      const row = target.closest('[data-row]');
      if (target.checked && checkedRows().length > max) {
        target.checked = false;
        say(texts.too_many);
      } else if (!target.checked && radioOf(row).checked) {
        target.checked = true;
        say(texts.keep_default);
      } else {
        say('');
      }
      sync();
    } else if (target.matches('[data-default-radio]')) {
      say('');
      sync();
    }
  });

  if (addSelect) {
    addSelect.addEventListener('change', () => {
      const id = addSelect.value;
      if (!id) return;
      const option = addSelect.options[addSelect.selectedIndex];
      if (checkedRows().length >= max && !(rowFor(id) && checkOf(rowFor(id)).checked)) {
        say(texts.too_many);
      } else {
        const row = rowFor(id) || buildRow({
          id,
          name: option.dataset.name || id,
          meta: [option.dataset.price, (option.dataset.badges || '').split(',').filter(Boolean).join(', ')]
            .filter(Boolean)
            .join(' · '),
          note: option.dataset.note || '',
        });
        checkOf(row).checked = true;
        say('');
        fire(checkOf(row));
      }
      // the select only adds: it goes back to its first option
      addSelect.value = '';
      fire(addSelect);
      sync();
    });
  }

  // the default model has to stay on the list: otherwise it is the model of the platform
  const keepDefaultOnList = () => {
    const row = defaultRadio().closest('[data-row]');
    if (!row || !checkOf(row).checked) platformRadio().checked = true;
  };

  const tickOnly = ids => {
    rows().forEach(row => {
      checkOf(row).checked = ids.includes(row.dataset.modelId);
    });
    keepDefaultOnList();
  };

  if (resetButton) {
    resetButton.hidden = false;
    resetButton.addEventListener('click', () => {
      tickOnly(recommended.filter(id => rowFor(id)));
      say('');
      sync();
      fire(resetButton.closest('[data-checklist]'));
    });
  }

  // «Вернуть» / «Вернуть встроенную» of the list and of the default model
  card.addEventListener(SET_VALUE_EVENT, event => {
    const { key, value } = event.detail;
    if (key === LIST_KEY) {
      event.preventDefault();
      const ids = parseList(value);
      ids.forEach(id => tick(id));
      tickOnly(ids);
      sync();
      fire(rowsBox);
    } else if (key === DEFAULT_KEY) {
      event.preventDefault();
      if (value) {
        const row = tick(value);
        radioOf(row).checked = true;
      } else {
        platformRadio().checked = true;
      }
      sync();
      fire(rowsBox);
    }
  });

  // the form was reset: the rows that were added are gone, the others are as the server drew them
  const onReset = () => {
    rows().filter(row => row.dataset.added).forEach(row => row.remove());
    sync();
  };
  card.closest('[data-ai-models]')?.addEventListener(RESET_EVENT, onReset);

  sync();
  return { sync, rows, tick, tickOnly };
};
