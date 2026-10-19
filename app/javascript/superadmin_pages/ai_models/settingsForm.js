// What changed in the form of the «Модели ИИ» page, and what to do about it: the sticky bar «Изменено N настроек —
// Сохранить / Отменить», the mark «Не сохранено» on a card, the warning before the page is left, and the buttons
// «Вернуть встроенную» / «Вернуть» that put an earlier value into the form (nothing is saved until «Сохранить»).

export const RESET_EVENT = 'ai:reset';
export const SET_VALUE_EVENT = 'ai:set-value';
export const CHANGE_EVENT = 'ai:changed';

const SETTING_NAME = /^app_config\[([^\]]+)\](\[\])?$/;

// `app_config[CAPTAIN_DEFAULT_MODEL]` and `app_config[CAPTAIN_ASSISTANT_MODEL_ALLOWLIST][]` => the name of the setting
export const settingKey = name => {
  const match = SETTING_NAME.exec(name || '');
  return match ? match[1] : null;
};

// The value of every setting of the form as one text (a list is its sorted items: the order of the ticks is not a choice)
export const snapshot = form => {
  const values = {};
  new FormData(form).forEach((value, name) => {
    const key = settingKey(name);
    if (!key || typeof value !== 'string') return;
    (values[key] = values[key] || []).push(value);
  });
  return Object.fromEntries(
    Object.entries(values).map(([key, list]) => [
      key,
      list
        .filter(item => item !== '')
        .sort()
        .join('\u0000'),
    ])
  );
};

export const changedKeys = (initial, current, forced = []) => {
  const keys = new Set([...Object.keys(initial), ...Object.keys(current)]);
  const changed = Array.from(keys).filter(
    key => (initial[key] || '') !== (current[key] || '')
  );
  return Array.from(new Set([...changed, ...forced]));
};

const FORMS = ['one', 'few', 'many', 'other'];

export const countText = (texts, count) => {
  const form = new Intl.PluralRules('ru').select(count);
  const template =
    (texts.changed || {})[FORMS.includes(form) ? form : 'other'] || '';
  return template.replace('%{count}', String(count));
};

// A plain select of one model: a saved model the list does not offer is added so that it can be put back
export const setSelectValue = (form, key, value) => {
  const select = form.querySelector(`select[name="app_config[${key}]"]`);
  if (!select) return false;
  if (!Array.from(select.options).some(option => option.value === value)) {
    const option = select.ownerDocument.createElement('option');
    option.value = value;
    option.textContent = value;
    option.dataset.name = value;
    select.appendChild(option);
  }
  select.value = value;
  select.dispatchEvent(new Event('input', { bubbles: true }));
  select.dispatchEvent(new Event('change', { bubbles: true }));
  return true;
};

export const initSettingsForm = (
  page,
  form,
  texts = {},
  { navigate = url => window.location.assign(url) } = {}
) => {
  const bar = form.querySelector('[data-savebar]');
  const barText = form.querySelector('[data-savebar-text]');
  const cancel = form.querySelector('[data-savebar-cancel]');
  const forced = (page.dataset.unsavedKeys || '').split(/\s+/).filter(Boolean);
  // «Вернуть встроенную» / «Вернуть» work only with the script: they are hidden until it runs
  page.querySelectorAll('[data-revert][hidden]').forEach(button => {
    button.hidden = false;
  });
  let initial = snapshot(form);
  let submitting = false;
  let dirty = [];

  const update = () => {
    dirty = changedKeys(initial, snapshot(form), forced);
    page.querySelectorAll('[data-config]').forEach(card => {
      const keys = card.dataset.config.split(/\s+/);
      const isDirty = keys.some(key => dirty.includes(key));
      const badge = card.querySelector('[data-unsaved-badge]');
      if (badge) badge.hidden = !isDirty;
    });
    if (bar) {
      bar.hidden = dirty.length === 0;
      if (barText) barText.textContent = countText(texts, dirty.length);
    }
    page.dispatchEvent(
      new CustomEvent(CHANGE_EVENT, { detail: { keys: dirty } })
    );
    return dirty;
  };

  form.addEventListener('input', update);
  form.addEventListener('change', update);
  form.addEventListener('submit', () => {
    submitting = true;
  });

  const warnBeforeLeaving = event => {
    if (submitting || dirty.length === 0) return undefined;
    event.preventDefault();
    // eslint-disable-next-line no-param-reassign
    event.returnValue = texts.leave || '';
    return texts.leave || '';
  };
  window.addEventListener('beforeunload', warnBeforeLeaving);

  if (cancel) {
    cancel.addEventListener('click', () => {
      // what the server refused is not in the form as it was saved: ask for the page again
      if (forced.length) {
        navigate(form.dataset.cancelUrl || window.location.pathname);
        return;
      }
      form.reset();
      page.dispatchEvent(new CustomEvent(RESET_EVENT));
      update();
    });
  }

  // «Вернуть встроенную» / «Вернуть»: put a value into the control of the setting
  page.addEventListener('click', event => {
    const button = event.target.closest('[data-revert]');
    if (!button) return;
    event.preventDefault();
    const detail = {
      key: button.dataset.revert,
      value: button.dataset.revertValue || '',
    };
    const handled = !button.dispatchEvent(
      new CustomEvent(SET_VALUE_EVENT, {
        detail,
        bubbles: true,
        cancelable: true,
      })
    );
    if (!handled) setSelectValue(form, detail.key, detail.value);
    update();
  });

  page.addEventListener(RESET_EVENT, () => {
    initial = snapshot(form);
  });
  // the page can be shown again from the cache of the browser with what was typed before
  window.addEventListener('pageshow', update);

  update();
  return {
    update,
    dirty: () => dirty,
    destroy: () => {
      window.removeEventListener('beforeunload', warnBeforeLeaving);
      window.removeEventListener('pageshow', update);
    },
  };
};
