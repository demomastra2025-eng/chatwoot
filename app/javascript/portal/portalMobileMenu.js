const initializedMenus = new WeakSet();

const getMenuElements = () => ({
  toggle: document.getElementById('mobile-menu-toggle'),
  trigger: document.getElementById('mobile-menu-open'),
  menu: document.getElementById('mobile-menu'),
});

const updateMenu = (isOpen, { restoreFocus = true } = {}) => {
  const { toggle, trigger, menu } = getMenuElements();
  if (!toggle || !trigger || !menu) return;

  toggle.checked = isOpen;
  trigger.setAttribute('aria-expanded', String(isOpen));
  menu.setAttribute('aria-hidden', String(!isOpen));
  menu.inert = !isOpen;

  if (isOpen) {
    menu.querySelector('[data-mobile-menu-close]')?.focus();
  } else if (restoreFocus) {
    trigger.focus();
  }
};

export const closeMobileMenu = () => {
  if (getMenuElements().toggle?.checked) updateMenu(false);
};

export const initializeMobileMenu = () => {
  const { toggle, trigger, menu } = getMenuElements();
  if (!toggle || !trigger || !menu || initializedMenus.has(menu)) return;
  initializedMenus.add(menu);
  updateMenu(false, { restoreFocus: false });

  trigger.addEventListener('click', () => updateMenu(!toggle.checked));
  menu
    .querySelector('[data-mobile-menu-close]')
    ?.addEventListener('click', closeMobileMenu);
  toggle.addEventListener('change', () => updateMenu(toggle.checked));

  menu.addEventListener('keydown', event => {
    if (!toggle.checked) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      closeMobileMenu();
      return;
    }
    if (event.key !== 'Tab') return;

    const controls = menu.querySelectorAll(
      'button:not([disabled]), a[href], select:not([disabled]), [tabindex="0"]'
    );
    const first = controls[0];
    const last = controls[controls.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first?.focus();
    }
  });
};
