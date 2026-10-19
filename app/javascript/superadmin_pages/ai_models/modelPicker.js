// The searchable list of models of the «Модели ИИ» page.
//
// The server renders a plain <select> (it works without a script, and it is what the form posts): every <option> carries
// the readable name, the price, the badges and the company of the model in data attributes, and the groups are
// <optgroup>s. This module hides the select and puts a button and a panel with a search box in its place; the value is
// always written back to the select (and `input` / `change` are fired on it), so the form, the dirty check and the
// buttons «Вернуть» see no difference.

let counter = 0;

const create = (doc, tag, className, text) => {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// Every token of the query has to be a part of the text: «gpt 5 luna» finds «OpenAI: GPT-5 Luna»
export const matchesQuery = (text, query) => {
  const tokens = String(query || '')
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);
  const haystack = String(text || '').toLowerCase();
  return tokens.every(token => haystack.includes(token));
};

// The entries of a select in the order of the list: a group title, then its options
export const readEntries = select => {
  const entries = [];
  const pushOption = (option, group) => {
    const { dataset } = option;
    entries.push({
      type: 'option',
      value: option.value,
      name: dataset.name || option.textContent.trim(),
      price: dataset.price || '',
      badges: (dataset.badges || '').split(',').filter(Boolean),
      provider: dataset.provider || '',
      note: dataset.note || '',
      kind: dataset.kind || '',
      group,
    });
  };
  Array.from(select.children).forEach(child => {
    if (child.tagName === 'OPTGROUP') {
      entries.push({ type: 'group', label: child.label });
      Array.from(child.children).forEach(option => pushOption(option, child.label));
    } else if (child.tagName === 'OPTION') {
      pushOption(child, '');
    }
  });
  return entries;
};

const searchText = entry =>
  [entry.value, entry.name, entry.provider, entry.note].join(' ');

const describe = (doc, entry) => {
  const name = create(doc, 'span', 'admin-combo__name', entry.name);
  const meta = create(doc, 'span', 'admin-combo__meta');
  if (entry.price) meta.appendChild(create(doc, 'span', '', entry.price));
  entry.badges.forEach(badge =>
    meta.appendChild(create(doc, 'span', 'admin-combo__badge', badge))
  );
  if (entry.note) {
    meta.appendChild(
      create(doc, 'span', 'admin-combo__badge admin-combo__badge--warn', entry.note)
    );
  }
  return [name, meta];
};

export const enhanceModelSelect = (select, texts = {}) => {
  if (!select || select.dataset.enhanced === 'true') return null;
  const doc = select.ownerDocument;
  counter += 1;
  const listId = `model-list-${counter}`;
  const triggerId = `model-trigger-${counter}`;
  const entries = readEntries(select);

  const wrapper = create(doc, 'div', 'admin-combo');
  const trigger = create(doc, 'button', 'admin-combo__trigger reset-base');
  trigger.type = 'button';
  trigger.id = triggerId;
  trigger.setAttribute('role', 'combobox');
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', 'false');
  trigger.setAttribute('aria-controls', listId);
  const value = create(doc, 'span', 'admin-combo__value');
  const chevron = create(doc, 'span', 'admin-combo__chevron i-lucide-chevron-down size-4');
  chevron.setAttribute('aria-hidden', 'true');
  trigger.append(value, chevron);

  const panel = create(doc, 'div', 'admin-combo__panel');
  panel.hidden = true;
  const search = create(doc, 'input');
  search.type = 'search';
  search.className = 'admin-combo__search';
  search.placeholder = texts.search || '';
  search.setAttribute('aria-label', texts.search || '');
  search.setAttribute('aria-controls', listId);
  search.autocomplete = 'off';
  const list = create(doc, 'ul', 'admin-combo__list');
  list.id = listId;
  list.setAttribute('role', 'listbox');
  const empty = create(doc, 'p', 'admin-combo__empty', texts.nothing_found || '');
  empty.hidden = true;
  panel.append(search, list, empty);
  wrapper.append(trigger, panel);

  const items = entries.map((entry, index) => {
    if (entry.type === 'group') {
      const li = create(doc, 'li', 'admin-combo__group', entry.label);
      li.setAttribute('role', 'presentation');
      return { entry, node: li };
    }
    const li = create(doc, 'li', 'admin-combo__option');
    li.id = `${listId}-${index}`;
    li.setAttribute('role', 'option');
    li.dataset.value = entry.value;
    describe(doc, entry).forEach(part => li.appendChild(part));
    return { entry, node: li };
  });
  items.forEach(item => list.appendChild(item.node));

  let activeIndex = -1;

  const optionItems = () => items.filter(item => item.entry.type === 'option');
  const visibleOptions = () => optionItems().filter(item => !item.node.hidden);

  const selectedOption = () => select.options[select.selectedIndex] || null;

  const selectedEntry = () => {
    const option = selectedOption();
    return option ? optionItems().find(item => item.entry.value === option.value) : null;
  };

  const renderTrigger = () => {
    const current = selectedEntry();
    if (current) {
      value.replaceChildren(...describe(doc, current.entry));
    } else {
      // a value the list was not built with (put back by «Вернуть»): its own text
      const option = selectedOption();
      const text = option ? option.dataset.name || option.textContent.trim() : '';
      value.replaceChildren(create(doc, 'span', 'admin-combo__name', text));
    }
    optionItems().forEach(item => {
      const isSelected = current && item === current;
      item.node.setAttribute('aria-selected', isSelected ? 'true' : 'false');
    });
    if (select.getAttribute('aria-invalid') === 'true') {
      wrapper.dataset.invalid = 'true';
    }
  };

  const setActive = index => {
    const options = visibleOptions();
    optionItems().forEach(item => item.node.removeAttribute('data-active'));
    if (!options.length) {
      activeIndex = -1;
      search.removeAttribute('aria-activedescendant');
      return;
    }
    activeIndex = (index + options.length) % options.length;
    const node = options[activeIndex].node;
    node.setAttribute('data-active', 'true');
    search.setAttribute('aria-activedescendant', node.id);
    if (node.scrollIntoView) node.scrollIntoView({ block: 'nearest' });
  };

  const filter = () => {
    const query = search.value;
    optionItems().forEach(item => {
      item.node.hidden = !matchesQuery(searchText(item.entry), query);
    });
    // a group title stays only while one of its options does
    items.forEach((item, index) => {
      if (item.entry.type !== 'group') return;
      let visible = false;
      for (let next = index + 1; next < items.length && items[next].entry.type === 'option'; next += 1) {
        if (!items[next].node.hidden) visible = true;
      }
      item.node.hidden = !visible;
    });
    empty.hidden = visibleOptions().length > 0;
    setActive(0);
  };

  const close = ({ focus = false } = {}) => {
    if (panel.hidden) return;
    panel.hidden = true;
    trigger.setAttribute('aria-expanded', 'false');
    doc.removeEventListener('mousedown', onOutside, true);
    if (focus) trigger.focus();
  };

  const open = () => {
    if (!panel.hidden) return;
    search.value = '';
    filter();
    panel.hidden = false;
    trigger.setAttribute('aria-expanded', 'true');
    doc.addEventListener('mousedown', onOutside, true);
    const current = selectedEntry();
    const options = visibleOptions();
    setActive(Math.max(0, options.findIndex(item => item === current)));
    search.focus();
  };

  function onOutside(event) {
    if (!wrapper.contains(event.target)) close();
  }

  const choose = item => {
    if (!item) return;
    select.value = item.entry.value;
    select.dispatchEvent(new Event('input', { bubbles: true }));
    select.dispatchEvent(new Event('change', { bubbles: true }));
    renderTrigger();
    close({ focus: true });
  };

  trigger.addEventListener('click', () => (panel.hidden ? open() : close()));
  trigger.addEventListener('keydown', event => {
    if (['ArrowDown', 'ArrowUp'].includes(event.key)) {
      event.preventDefault();
      open();
    }
  });
  search.addEventListener('input', filter);
  search.addEventListener('keydown', event => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setActive(activeIndex + 1);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActive(activeIndex - 1);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      choose(visibleOptions()[activeIndex]);
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close({ focus: true });
    } else if (event.key === 'Tab') {
      close();
    }
  });
  list.addEventListener('click', event => {
    const node = event.target.closest('[role="option"]');
    if (node) choose(optionItems().find(item => item.node === node));
  });
  list.addEventListener('mousemove', event => {
    const node = event.target.closest('[role="option"]');
    const index = visibleOptions().findIndex(item => item.node === node);
    if (index >= 0 && index !== activeIndex) setActive(index);
  });
  // the value is changed from outside (the «Вернуть» buttons, a reset of the form)
  select.addEventListener('change', renderTrigger);

  const label = select.id ? doc.querySelector(`label[for="${select.id}"]`) : null;
  if (label) {
    if (!label.id) label.id = `${triggerId}-label`;
    trigger.setAttribute('aria-labelledby', `${label.id} ${triggerId}`);
    label.setAttribute('for', triggerId);
  }

  select.insertAdjacentElement('afterend', wrapper);
  select.hidden = true;
  select.tabIndex = -1;
  select.dataset.enhanced = 'true';
  renderTrigger();

  return {
    wrapper,
    trigger,
    refresh: renderTrigger,
    open,
    close,
  };
};

export const enhanceAll = (root, texts) =>
  Array.from(root.querySelectorAll('select[data-model-select]')).map(select =>
    enhanceModelSelect(select, texts)
  );
