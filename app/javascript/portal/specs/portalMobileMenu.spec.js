import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { closeMobileMenu, initializeMobileMenu } from '../portalMobileMenu';
import { initializeThemeHandlers } from '../portalThemeHelper';

const menuTemplate = readFileSync(
  resolve('app/views/public/api/v1/portals/_mobile_menu.html.erb'),
  'utf8'
).replace(/<%[\s\S]*?%>/g, '');

const waitForMenuPaint = () =>
  new Promise(finishPaint => {
    requestAnimationFrame(() => requestAnimationFrame(finishPaint));
  });

describe('portal native mobile menu', () => {
  let trigger;
  let menu;
  let toggle;
  let close;

  beforeEach(() => {
    document.body.innerHTML = menuTemplate;
    trigger = document.getElementById('mobile-menu-open');
    menu = document.getElementById('mobile-menu');
    toggle = document.getElementById('mobile-menu-toggle');
    close = menu.querySelector('[data-mobile-menu-close]');
    initializeMobileMenu();
  });

  afterEach(() => {
    document.body.innerHTML = '';
    document.documentElement.classList.remove('dark', 'light');
    localStorage.clear();
    delete window.portalConfig;
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('uses native buttons and opens the existing menu with focus on close', async () => {
    expect(trigger.tagName).toBe('BUTTON');
    expect(close.tagName).toBe('BUTTON');
    expect(menu.inert).toBe(true);
    trigger.focus();
    trigger.click();
    await waitForMenuPaint();

    expect(toggle.checked).toBe(true);
    expect(trigger.getAttribute('aria-expanded')).toBe('true');
    expect(menu.getAttribute('aria-hidden')).toBe('false');
    expect(menu.inert).toBe(false);
    expect(document.activeElement).toBe(close);
  });

  it('closes with Escape and restores focus to the trigger', () => {
    trigger.click();
    close.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
    );

    expect(toggle.checked).toBe(false);
    expect(trigger.getAttribute('aria-expanded')).toBe('false');
    expect(menu.getAttribute('aria-hidden')).toBe('true');
    expect(document.activeElement).toBe(trigger);
  });

  it('does not move focus into a menu closed or removed before opening paints', async () => {
    trigger.focus();
    trigger.click();
    await new Promise(requestAnimationFrame);
    closeMobileMenu();
    await waitForMenuPaint();
    expect(menu.inert).toBe(true);
    expect(document.activeElement).toBe(trigger);

    trigger.click();
    await new Promise(requestAnimationFrame);
    menu.remove();
    await waitForMenuPaint();
    expect(document.activeElement).toBe(trigger);
  });

  it('keeps Tab and Shift+Tab within the open menu', async () => {
    trigger.click();
    await waitForMenuPaint();
    const last = menu.querySelector('a[href]');
    close.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'Tab',
        shiftKey: true,
        bubbles: true,
        cancelable: true,
      })
    );
    expect(document.activeElement).toBe(last);
    last.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'Tab',
        bubbles: true,
        cancelable: true,
      })
    );
    expect(document.activeElement).toBe(close);
  });

  it('closes from its button and is safe to initialize repeatedly', () => {
    initializeMobileMenu();
    trigger.click();
    expect(toggle.checked).toBe(true);
    close.click();
    expect(toggle.checked).toBe(false);
    expect(document.activeElement).toBe(trigger);
    trigger.click();
    closeMobileMenu();
    expect(toggle.checked).toBe(false);
  });

  it('retains the theme and language controls and closes after a theme choice', () => {
    vi.useFakeTimers();
    document.body.insertAdjacentHTML(
      'beforeend',
      '<button id="toggle-appearance"></button><div id="appearance-dropdown"></div>'
    );
    window.portalConfig = { portalColor: '#1864ab' };
    initializeThemeHandlers();
    trigger.click();
    expect(menu.querySelector('.locale-switcher')).not.toBeNull();
    menu.querySelector('[data-theme="dark"]').click();

    expect(localStorage.theme).toBe('dark');
    expect(document.documentElement.classList.contains('dark')).toBe(true);
    vi.advanceTimersByTime(300);
    expect(toggle.checked).toBe(false);
    expect(menu.inert).toBe(true);
    expect(document.activeElement).toBe(trigger);
  });
});
