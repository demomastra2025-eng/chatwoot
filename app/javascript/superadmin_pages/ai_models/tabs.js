// The tabs «Подключение / Модели / Промпты». The server renders the panels one under another and the tab buttons hidden;
// with a script the buttons appear and one panel is shown at a time. Every panel stays in the form, so one «Сохранить»
// saves them all. The tab with an error is opened first, and a tab that has unsaved changes or an error gets a dot.

export const initTabs = (page, { hash = true } = {}) => {
  const list = page.querySelector('[data-tablist]');
  const panels = Array.from(page.querySelectorAll('[data-tab-panel]'));
  if (!list || panels.length === 0) return null;
  const buttons = Array.from(list.querySelectorAll('[data-tab]'));
  const nameOf = panel => panel.dataset.tabPanel;

  const select = (name, { focus = false } = {}) => {
    buttons.forEach(button => {
      const active = button.dataset.tab === name;
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.tabIndex = active ? 0 : -1;
      if (active && focus) button.focus();
    });
    panels.forEach(panel => {
      // eslint-disable-next-line no-param-reassign
      panel.hidden = nameOf(panel) !== name;
    });
    if (hash && window.history && window.history.replaceState) {
      window.history.replaceState(null, '', `#${name}`);
    }
  };

  const markDots = () => {
    panels.forEach(panel => {
      const button = buttons.find(
        candidate => candidate.dataset.tab === nameOf(panel)
      );
      const dot = button && button.querySelector('[data-tab-dot]');
      if (!dot) return;
      const hasError = Boolean(panel.querySelector('[data-error-for]'));
      const hasChange = Boolean(
        panel.querySelector('[data-unsaved-badge]:not([hidden])')
      );
      dot.hidden = !(hasError || hasChange);
      dot.classList.toggle('admin-tab__dot--error', hasError);
    });
  };

  const firstWithError = panels.find(panel =>
    panel.querySelector('[data-error-for]')
  );
  const fromHash = hash ? window.location.hash.replace('#', '') : '';
  const start =
    (firstWithError && nameOf(firstWithError)) ||
    (panels.some(panel => nameOf(panel) === fromHash)
      ? fromHash
      : nameOf(panels[0]));

  list.hidden = false;
  page.classList.add('admin-tabs-ready');
  select(start);
  markDots();

  buttons.forEach(button =>
    button.addEventListener('click', () => select(button.dataset.tab))
  );
  list.addEventListener('keydown', event => {
    const index = buttons.findIndex(
      button => button.getAttribute('aria-selected') === 'true'
    );
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
    if (!step) return;
    event.preventDefault();
    select(
      buttons[(index + step + buttons.length) % buttons.length].dataset.tab,
      { focus: true }
    );
  });
  page.addEventListener('ai:changed', markDots);

  return { select, markDots };
};
