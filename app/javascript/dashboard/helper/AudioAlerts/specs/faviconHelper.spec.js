import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { startFaviconBlinking, stopFaviconBlinking } from '../faviconHelper';

const originalVisibilityState = Object.getOwnPropertyDescriptor(
  document,
  'visibilityState'
);

const setVisibilityState = value => {
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    value,
  });
};

const faviconPath = () =>
  document.querySelector('.favicon').getAttribute('href');

describe('faviconHelper', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.head.innerHTML =
      '<link class="favicon" rel="icon" sizes="16x16" href="/favicon-16x16.png">';
  });

  afterEach(() => {
    stopFaviconBlinking();
    document.head.innerHTML = '';
    if (originalVisibilityState) {
      Object.defineProperty(
        document,
        'visibilityState',
        originalVisibilityState
      );
    } else {
      delete document.visibilityState;
    }
    vi.useRealTimers();
  });

  it('alternates the notification badge while the tab is hidden', () => {
    setVisibilityState('hidden');

    startFaviconBlinking();

    expect(faviconPath()).toBe('/favicon-badge-16x16.png');
    expect(vi.getTimerCount()).toBe(1);

    vi.advanceTimersByTime(1000);
    expect(faviconPath()).toBe('/favicon-16x16.png');

    vi.advanceTimersByTime(1000);
    expect(faviconPath()).toBe('/favicon-badge-16x16.png');
  });

  it('does not blink when the tab is already visible', () => {
    setVisibilityState('visible');

    startFaviconBlinking();
    vi.advanceTimersByTime(2000);

    expect(faviconPath()).toBe('/favicon-16x16.png');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('restores the regular favicon when the tab becomes visible', () => {
    setVisibilityState('hidden');
    startFaviconBlinking();

    setVisibilityState('visible');
    document.dispatchEvent(new Event('visibilitychange'));

    expect(faviconPath()).toBe('/favicon-16x16.png');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('keeps a single timer when multiple notifications arrive', () => {
    setVisibilityState('hidden');

    startFaviconBlinking();
    startFaviconBlinking();

    expect(vi.getTimerCount()).toBe(1);
  });

  it('blinks the real layout icons and restores their branded URLs', () => {
    document.head.innerHTML = `
      <link rel="icon" href="/favicon.ico?v=onelink-brand">
      <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png?v=onelink-brand">
      <link rel="icon" type="image/svg+xml" sizes="any" href="/favicon.svg?v=onelink-brand">
    `;
    const originalHrefs = Array.from(
      document.querySelectorAll('link[rel~="icon"]')
    ).map(icon => icon.getAttribute('href'));
    setVisibilityState('hidden');

    startFaviconBlinking();

    expect(
      Array.from(document.querySelectorAll('link[rel~="icon"]')).map(icon =>
        icon.getAttribute('href')
      )
    ).toEqual([
      '/favicon-badge-32x32.png',
      '/favicon-badge-32x32.png',
      '/favicon-badge-32x32.png',
    ]);

    setVisibilityState('visible');
    document.dispatchEvent(new Event('visibilitychange'));

    expect(
      Array.from(document.querySelectorAll('link[rel~="icon"]')).map(icon =>
        icon.getAttribute('href')
      )
    ).toEqual(originalHrefs);
  });

  it('restores an icon that originally had no href', () => {
    document.head.innerHTML = '<link rel="icon" sizes="32x32">';
    const icon = document.querySelector('link[rel~="icon"]');
    setVisibilityState('hidden');

    startFaviconBlinking();
    stopFaviconBlinking();

    expect(icon.hasAttribute('href')).toBe(false);
  });

  it('preserves an externally changed branded URL on the same icon', () => {
    const icon = document.querySelector('.favicon');
    setVisibilityState('hidden');
    startFaviconBlinking();

    icon.setAttribute('href', '/tenant-favicon-16x16.png?v=2');
    stopFaviconBlinking();

    expect(icon.getAttribute('href')).toBe('/tenant-favicon-16x16.png?v=2');
  });
});
