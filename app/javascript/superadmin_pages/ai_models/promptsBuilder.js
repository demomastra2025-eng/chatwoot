// The builder of the rules of the platform (system prompts) on the «Промпты» tab.
//
// The rules go to the server as one JSON text in a hidden field. A rule has a group and a place in the prompt, both chosen
// from lists with Russian names (a group typed by hand would open a new group, a place with a typo would turn the rule into
// an ordinary one). A group or a place a saved rule already has but the lists do not know stays selectable, marked as its
// own, so it is not lost. A rule is deleted only after a question; an empty new rule is just dropped.

import { RESET_EVENT } from './settingsForm';

const nextPromptId = () =>
  `system_prompt_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

export const serializePrompts = rows =>
  JSON.stringify(
    rows
      .map(row => ({
        id: row.querySelector('[data-field="id"]').value || nextPromptId(),
        type: 'system',
        group: row.querySelector('[data-field="group"]').value,
        content: row.querySelector('[data-field="content"]').value.trim(),
        slot: row.querySelector('[data-field="slot"]').value || null,
      }))
      .filter(prompt => prompt.content)
  );

const ensureOption = (select, value, template) => {
  if (
    !value ||
    Array.from(select.options).some(option => option.value === value)
  )
    return;
  const option = select.ownerDocument.createElement('option');
  option.value = value;
  option.textContent = (template || '%{value}').replace('%{value}', value);
  select.appendChild(option);
};

export const initPromptsBuilder = (builder, texts = {}) => {
  if (!builder) return null;
  const hidden = builder.ownerDocument.getElementById(
    builder.dataset.targetInput
  );
  const rowsBox = builder.querySelector('[data-role="rows"]');
  const template = builder.querySelector('template');
  const addButton = builder.querySelector('[data-role="add"]');
  const empty = builder.querySelector('[data-role="empty"]');
  const initial = hidden ? hidden.value : '[]';

  const rows = () =>
    Array.from(rowsBox.querySelectorAll('[data-role="prompt-row"]'));

  const renumber = () => {
    rows().forEach((row, index) => {
      row.querySelector('[data-role="title"]').textContent =
        `${texts.prompt_title || ''} ${index + 1}`.trim();
    });
    if (empty) empty.hidden = rows().length > 0;
  };

  const sync = () => {
    if (hidden) hidden.value = serializePrompts(rows());
  };

  // the hidden field is changed by the script, so the form is told by hand
  const notify = () => {
    sync();
    if (hidden) {
      hidden.dispatchEvent(new Event('input', { bubbles: true }));
      hidden.dispatchEvent(new Event('change', { bubbles: true }));
    }
  };

  const bindRow = row => {
    row.querySelectorAll('[data-field]').forEach(field => {
      field.addEventListener('input', sync);
      field.addEventListener('change', sync);
    });
    const confirm = row.querySelector('[data-role="confirm"]');
    const remove = row.querySelector('[data-role="remove"]');
    const dropRow = () => {
      row.remove();
      renumber();
      notify();
    };
    remove.addEventListener('click', () => {
      // a rule nobody has written yet needs no question
      if (!row.querySelector('[data-field="content"]').value.trim()) {
        dropRow();
        return;
      }
      confirm.hidden = false;
      remove.hidden = true;
    });
    row
      .querySelector('[data-role="remove-yes"]')
      .addEventListener('click', dropRow);
    row
      .querySelector('[data-role="remove-no"]')
      .addEventListener('click', () => {
        confirm.hidden = true;
        remove.hidden = false;
      });
  };

  const addRow = (prompt = {}) => {
    const fragment = template.content.cloneNode(true);
    const row = fragment.querySelector('[data-role="prompt-row"]');
    const group = row.querySelector('[data-field="group"]');
    const slot = row.querySelector('[data-field="slot"]');
    row.querySelector('[data-field="id"]').value = prompt.id || nextPromptId();
    ensureOption(group, prompt.group, texts.custom_group);
    ensureOption(slot, prompt.slot, texts.custom_slot);
    if (prompt.group) group.value = prompt.group;
    slot.value = prompt.slot || '';
    row.querySelector('[data-field="content"]').value = prompt.content || '';
    bindRow(row);
    rowsBox.appendChild(fragment);
    renumber();
    return row;
  };

  const load = text => {
    rows().forEach(row => row.remove());
    let prompts = [];
    try {
      prompts = JSON.parse(text || '[]');
    } catch (error) {
      prompts = [];
    }
    (Array.isArray(prompts) ? prompts : []).forEach(addRow);
    renumber();
  };

  load(builder.dataset.initialPrompts || initial);
  // the rows are drawn from the saved rules: the hidden field says the same
  if (hidden) hidden.value = serializePrompts(rows());

  if (addButton) {
    addButton.hidden = false;
    addButton.addEventListener('click', () => {
      const row = addRow({});
      row.querySelector('[data-field="content"]').focus();
    });
  }

  builder.closest('form')?.addEventListener('submit', sync);
  builder.closest('[data-ai-models]')?.addEventListener(RESET_EVENT, () => {
    load(builder.dataset.initialPrompts || initial);
    sync();
  });

  return { rows, addRow, sync, load };
};
